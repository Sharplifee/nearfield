import Foundation
import AVFoundation
import Accelerate

/// Ultrasonic time-of-flight between two devices you control.
///
/// TWO JOBS, one session:
///  1. Ranging — a 18-21 kHz linear chirp is inaudible to most adults, passes room acoustics
///     acceptably, and cross-correlates to sub-millisecond timing. At 343 m/s that is ~0.3 m.
///  2. PERSISTENCE — a continuously running AVAudioSession is the strongest legal background
///     anchor on iOS and doubles as the intercom transport in the Home Monitoring System.
///     This is the exact mechanism already chosen for HMS; here it earns a second job.
///
/// Requires both devices running the app with clocks synchronised over the local network
/// (round-trip NTP-style offset estimate). Absolute ToF needs a shared clock; two-way ranging
/// does not, which is why we do two-way.
@MainActor
final class AcousticRanging {

    private let engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private let sampleRate: Double = 48_000
    private let chirpDuration: Double = 0.020        // 20 ms
    private let f0: Double = 18_000
    private let f1: Double = 21_000

    var onObservation: (@MainActor (RFObservation) -> Void)?
    var observerPose: () -> SIMD3<Double> = { .zero }

    /// Category .playAndRecord with .mixWithOthers keeps the session alive without hijacking
    /// the user's audio. voiceChat mode disables the aggressive AGC that destroys chirp amplitude.
    func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord,
                                mode: .voiceChat,
                                options: [.mixWithOthers, .allowBluetooth, .defaultToSpeaker])
        try session.setPreferredSampleRate(sampleRate)
        try session.setActive(true)
    }

    func start() throws {
        try configureSession()
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: engine.inputNode.outputFormat(forBus: 0)) { [weak self] buffer, time in
            self?.process(buffer, at: time)
        }
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// Linear frequency sweep. Chirps beat single tones badly here — the sweep gives a sharp
    /// autocorrelation peak, so multipath echoes resolve as separate peaks instead of smearing.
    private func makeChirp(format: AVAudioFormat) -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(chirpDuration * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let ptr = buffer.floatChannelData![0]
        let k = (f1 - f0) / chirpDuration
        for i in 0..<Int(frames) {
            let t = Double(i) / sampleRate
            let phase = 2 * .pi * (f0 * t + 0.5 * k * t * t)
            // Hann window suppresses the audible click at chirp edges.
            let window = 0.5 * (1 - cos(2 * .pi * Double(i) / Double(frames - 1)))
            ptr[i] = Float(sin(phase) * window * 0.6)
        }
        return buffer
    }

    func emitChirp() {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        player.scheduleBuffer(makeChirp(format: format), at: nil, options: [])
        player.play()
    }

    private var reference: [Float] = []

    /// Matched filter. vDSP_conv against the known chirp; peak index gives sample delay.
    private func process(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        if reference.isEmpty {
            let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
            let chirp = makeChirp(format: format)
            reference = Array(UnsafeBufferPointer(start: chirp.floatChannelData![0],
                                                  count: Int(chirp.frameLength))).reversed()
        }
        guard n > reference.count else { return }
        var output = [Float](repeating: 0, count: n - reference.count + 1)
        vDSP_conv(channel, 1, reference, 1, &output, 1,
                  vDSP_Length(output.count), vDSP_Length(reference.count))

        var peak: Float = 0; var index: vDSP_Length = 0
        vDSP_maxvi(output, 1, &peak, &index, vDSP_Length(output.count))

        // Threshold against the running noise floor; a weak peak is an echo or a false lock.
        var mean: Float = 0
        vDSP_meanv(output, 1, &mean, vDSP_Length(output.count))
        guard peak > mean * 12 else { return }

        let delaySeconds = Double(index) / sampleRate
        let metres = delaySeconds * 343.0 / 2.0     // two-way
        guard metres > 0.2, metres < 15 else { return }

        onObservation?(RFObservation(
            targetID: "acoustic-peer", modality: .acousticToF, at: .now,
            observerPosition: observerPose(), observerHeading: nil,
            range: metres, rangeSigma: RFObservation.defaultSigma(.acousticToF)))
    }
}
