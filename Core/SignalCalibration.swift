import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// RSSI -> percentage, corrected for the receiving device's own radio.
/// iOS exposes RSSI only, never dBm — confirmed by the target's developer publicly.
///
/// The per-model offsets are the target's genuine unobservable asset (shipped in their 1.7.5).
/// These are placeholders. Replace by measurement: fixed reference beacon, fixed distance,
/// median RSSI over 60s per handset model, offset = median(model) - median(reference model).
enum SignalCalibration {

    /// dBm offset applied before normalisation. Positive = this model reads hot.
    private static let modelOffsets: [String: Int] = [
        "iPhone14,2": 0,    // iPhone 13 Pro — reference
        "iPhone15,2": 0,
        "iPhone15,3": 0,
        "iPhone16,1": 0,
        "iPhone17,1": 0,
        "iPad13,1":  -3,
        "Mac14,6":   -5
    ]

    static let deviceIdentifier: String = {
        var sysinfo = utsname(); uname(&sysinfo)
        return withUnsafeBytes(of: &sysinfo.machine) { raw in
            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
    }()

    private static var offset: Int { modelOffsets[deviceIdentifier] ?? 0 }

    /// CoreBluetooth returns 127 to mean "not available". Never render that as a signal.
    static func isValid(_ rssi: Int) -> Bool { rssi < 0 && rssi > -128 }

    /// Piecewise-linear rather than the naive (rssi + 100) — the top and bottom of the
    /// range are compressed in reality, which is why the target's users complain the bar
    /// "stops changing" within about 6 feet.
    static func percent(_ rssi: Int) -> Int? {
        guard isValid(rssi) else { return nil }
        let r = Double(rssi - offset)
        let p: Double = switch r {
        case (-45)... :        100 - (-45 - r) * 0.0
        case (-60)..<(-45):    100 + (r + 45) * (15.0 / 15.0)   // -45..-60 -> 100..85
        case (-75)..<(-60):     85 + (r + 60) * (25.0 / 15.0)   // -60..-75 ->  85..60
        case (-90)..<(-75):     60 + (r + 75) * (40.0 / 15.0)   // -75..-90 ->  60..20
        default:                max(0, 20 + (r + 90) * (20.0 / 10.0))
        }
        return Int(p.rounded().clamped(to: 0...100))
    }

    /// Free-space path loss estimate. Deliberately exposed as a range, not a number —
    /// the target's reviewers asked for a distance meter and a point estimate would lie.
    static func distanceRange(rssi: Int, txPower: Int?) -> ClosedRange<Double>? {
        guard isValid(rssi) else { return nil }
        let tx = Double(txPower ?? -59)
        let ratio = (tx - Double(rssi - offset)) / 20.0
        let mid = pow(10.0, ratio)
        return (mid * 0.5)...(mid * 2.0)   // +/- one octave; honest about multipath
    }
}

private extension Double {
    func clamped(to r: ClosedRange<Double>) -> Double { Swift.min(Swift.max(self, r.lowerBound), r.upperBound) }
}
