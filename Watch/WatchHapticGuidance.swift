import Foundation
import WatchKit

/// Eyes-free guidance. This is the whole reason the Watch earns its place in the hunt loop:
/// the operator can put the phone in a pocket, keep both hands free, and be steered by wrist
/// taps alone. Apple's own Precision Finding works this way for exactly this reason.
///
/// TWO CHANNELS ENCODED SIMULTANEOUSLY:
///   Distance -> pulse RATE (faster = closer). Humans read rate changes pre-attentively.
///   Bearing  -> pulse TYPE (.directionUp when aligned, .click when off, .failure when behind).
///
/// Do not encode bearing as rate as well. Two variables on one dimension is unreadable.
@MainActor
final class WatchHapticGuidance {

    private var timer: Task<Void, Never>?
    private(set) var current: GuidanceCommand.HapticPattern = .silent
    private var lastFired: Date = .distantPast

    /// Alignment window. Wider than it feels like it should be, because wrist heading noise
    /// is ±10-15° and a tight window produces a maddening flicker at the boundary.
    private let alignedWindow: Double = 35 * .pi / 180
    private let behindWindow: Double = 120 * .pi / 180

    func apply(_ command: GuidanceCommand, wristHeading: Double) {
        current = command.hapticPattern
        timer?.cancel()

        guard command.hapticPattern != .silent else { return }

        // Wrong floor overrides everything — no point steering someone horizontally toward
        // a device one storey up. Distinct double-buzz, then silence.
        if let floor = command.floorDelta, floor != 0 {
            timer = Task { @MainActor in
                for _ in 0..<3 {
                    WKInterfaceDevice.current().play(floor > 0 ? .directionUp : .directionDown)
                    try? await Task.sleep(for: .milliseconds(400))
                }
            }
            return
        }

        guard let distance = command.distance else {
            timer = Task { @MainActor in
                while !Task.isCancelled {
                    WKInterfaceDevice.current().play(.click)
                    try? await Task.sleep(for: .seconds(2))
                }
            }
            return
        }

        let error = command.bearing.map { angularError($0, wristHeading) }

        // Rate curve: 2 Hz at 0.5 m down to 0.25 Hz at 20 m. Logarithmic, because perceived
        // progress should feel linear while actual distance halves.
        let interval = max(0.35, min(4.0, 0.5 * log2(max(distance, 0.5)) + 0.5))

        timer = Task { @MainActor in
            while !Task.isCancelled {
                let haptic: WKHapticType
                switch (error, distance) {
                case (_, ..<0.6):                       haptic = .success        // arrived
                case let (e?, _) where abs(e) < alignedWindow:  haptic = .directionUp
                case let (e?, _) where abs(e) > behindWindow:   haptic = .failure
                case (_?, _):                           haptic = .click
                case (nil, _):                          haptic = .click
                }
                WKInterfaceDevice.current().play(haptic)
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stop() { timer?.cancel(); timer = nil; current = .silent }

    /// Signed smallest angle between two headings.
    private func angularError(_ target: Double, _ current: Double) -> Double {
        var d = target - current
        while d > .pi { d -= 2 * .pi }
        while d < -.pi { d += 2 * .pi }
        return d
    }
}
