import Foundation
import CoreBluetooth
import CoreMotion
import HealthKit
import WatchKit
import Observation

/// The Watch as an autonomous sensor node.
///
/// PERSISTENCE ON watchOS IS THE HARD PART, AND IT IS NOT THE SAME AS iOS.
/// There is no `bluetooth-central` background mode on watchOS. When the app leaves the
/// foreground, CoreBluetooth stops. Three escalating options:
///
///   1. WKExtendedRuntimeSession — ~1 hour, session types .physicalTherapy / .mindfulness /
///      .selfCare / .alarm / .smartAlarm. Honest fit for a bounded "hunt" session.
///   2. HKWorkoutSession — runs indefinitely with full sensor access while the workout is
///      active. This is the watchOS analogue of the continuous AVAudioSession trick on iOS.
///      Only legitimate if the user is actually moving; do not fake a workout to farm runtime.
///   3. Foreground with always-on display — the Watch keeps the app frontmost at reduced
///      refresh. Costs battery but is the most honest for an active search.
///
/// We default to (1) for hunts and expose (2) explicitly as "Survey Mode" for walking a
/// building, where a workout session is a truthful description of what the user is doing.
@Observable
@MainActor
final class WatchSensorNode: NSObject {

    enum Persistence: String, CaseIterable { case foreground, extendedRuntime, workout }

    private(set) var persistence: Persistence = .foreground
    private(set) var isScanning = false
    private(set) var visibleCount = 0
    private(set) var runtimeRemaining: TimeInterval?

    private var central: CBCentralManager?
    private let motion = CMMotionManager()
    private let altimeter = CMAltimeter()
    private var extendedSession: WKExtendedRuntimeSession?
    private let healthStore = HKHealthStore()
    private var workoutSession: HKWorkoutSession?

    private let link: DeviceLink
    private var focusTarget: String?
    private var lastAltitude: Double = 0

    // Wrist sweep state
    private(set) var sweeping = false
    private var sweepSamples: [WristSweep.Sample] = []
    private var sweepStart: Date?

    init(link: DeviceLink) {
        self.link = link
        super.init()
    }

    // MARK: Radio

    func startScanning(serviceFilter: [CBUUID]? = nil) {
        if central == nil {
            // No restore identifier — watchOS does not restore central managers.
            central = CBCentralManager(delegate: self, queue: DispatchQueue(label: "watch.central"))
        }
        guard central?.state == .poweredOn else { return }
        central?.scanForPeripherals(withServices: serviceFilter,
                                    options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        isScanning = true
    }

    func stopScanning() { central?.stopScan(); isScanning = false }

    // MARK: Persistence

    func beginExtendedRuntime() {
        let session = WKExtendedRuntimeSession()
        session.delegate = self
        session.start()
        extendedSession = session
        persistence = .extendedRuntime
    }

    /// Survey Mode. Only offered when the user is genuinely walking a site — the workout is a
    /// truthful record of that activity, not a runtime exploit.
    func beginSurveyWorkout() async throws {
        let config = HKWorkoutConfiguration()
        config.activityType = .walking
        config.locationType = .indoor
        let session = try HKWorkoutSession(healthStore: healthStore, configuration: config)
        session.startActivity(with: .now)
        workoutSession = session
        persistence = .workout
    }

    func endPersistence() {
        extendedSession?.invalidate()
        extendedSession = nil
        workoutSession?.end()
        workoutSession = nil
        persistence = .foreground
    }

    // MARK: Motion + barometer

    func startMotion() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 50
        motion.startDeviceMotionUpdates(using: .xArbitraryCorrectedZVertical, to: .main) { [weak self] dm, _ in
            guard let self, let dm, self.sweeping else { return }
            // Sweep samples are appended by the BLE callback; motion supplies the pose it stamps with.
            self.currentAttitude = (dm.heading * .pi / 180, dm.attitude.pitch, dm.attitude.roll)
        }
        guard CMAltimeter.isRelativeAltitudeAvailable() else { return }
        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
            guard let self, let data else { return }
            self.lastAltitude = data.relativeAltitude.doubleValue
            // Ship every altitude reading — the phone needs both barometers to difference them.
            self.link.send(.altitude(AltitudeReading(
                relativeAltitude: data.relativeAltitude.doubleValue,
                pressureKPa: data.pressure.doubleValue, at: .now, role: .watch)))
        }
    }

    private var currentAttitude: (heading: Double, pitch: Double, roll: Double) = (0, 0, 0)

    // MARK: Wrist sweep

    /// Operator raises the arm and rotates through roughly 360° over 4-6 seconds.
    /// Body shadowing modulates RSSI; the peak points at the transmitter.
    func beginWristSweep(targetID: String) {
        focusTarget = targetID
        sweepSamples.removeAll(keepingCapacity: true)
        sweepStart = .now
        sweeping = true
        WKInterfaceDevice.current().play(.start)
        startScanning()

        Task {
            try? await Task.sleep(for: .seconds(6))
            await self.endWristSweep()
        }
    }

    func endWristSweep() {
        guard sweeping, let start = sweepStart, let target = focusTarget else { return }
        sweeping = false
        let sweep = WristSweep(targetID: target, samples: sweepSamples,
                               startedAt: start, endedAt: .now)
        // Dynamic range below ~6 dB means the shadow pattern never developed — tell the phone,
        // but flag it so it is not fused as a confident bearing.
        link.send(.wristSweep(sweep), urgent: true)
        WKInterfaceDevice.current().play(sweep.dynamicRangeDB >= 6 ? .success : .failure)
    }
}

extension WatchSensorNode: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {}

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let id = peripheral.identifier.uuidString
        let rssi = RSSI.intValue
        Task { @MainActor in
            guard SignalCalibration.isValid(rssi) else { return }

            if self.sweeping, id == self.focusTarget {
                self.sweepSamples.append(WristSweep.Sample(
                    heading: self.currentAttitude.heading,
                    pitch: self.currentAttitude.pitch,
                    roll: self.currentAttitude.roll,
                    rssi: rssi, at: .now))
            }

            // Watch observations are position-tagged as "wrist" — the phone offsets them by the
            // measured body baseline rather than assuming both nodes are co-located.
            self.link.enqueue(WireObservation(
                targetID: id, modality: "bleRSSI", at: .now,
                observerPosition: [0, 0, self.lastAltitude],
                observerHeading: self.currentAttitude.heading,
                scalar: Double(rssi), sourceRole: .watch))
        }
    }
}

extension WatchSensorNode: WKExtendedRuntimeSessionDelegate {
    nonisolated func extendedRuntimeSessionDidStart(_ s: WKExtendedRuntimeSession) {}
    nonisolated func extendedRuntimeSessionWillExpire(_ s: WKExtendedRuntimeSession) {
        // ~2 minutes of warning. Flush everything and warn the wrist before the radio dies.
        Task { @MainActor in
            self.link.flush()
            WKInterfaceDevice.current().play(.retry)
        }
    }
    nonisolated func extendedRuntimeSession(_ s: WKExtendedRuntimeSession,
                                            didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
                                            error: Error?) {
        Task { @MainActor in
            self.persistence = .foreground
            self.stopScanning()
        }
    }
}
