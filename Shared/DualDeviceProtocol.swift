import Foundation
import simd

/// Wire protocol between the iPhone 16 Pro (fusion node) and the Apple Watch (remote sensor node).
///
/// DESIGN PRINCIPLE: the Watch is NOT a remote control and NOT a mirror. It is a second
/// observer at a different position in space, running its own radio. A single walking operator
/// produces highly correlated observation errors — every RSSI sample comes from essentially the
/// same body, same orientation, same multipath. Two independently-positioned receivers
/// decorrelate that, which is what actually makes trilateration converge indoors.

enum NodeRole: String, Codable, Sendable { case phone, watch }

/// Every message is one of these. Versioned because the two binaries ship independently
/// and WILL be out of step on someone's wrist for weeks.
struct NodeMessage: Codable, Sendable {
    static let currentVersion = 1
    var version: Int = Self.currentVersion
    var sender: NodeRole
    var sentAt: Date
    var monotonicNanos: UInt64        // for clock offset estimation, see ClockSync
    var payload: Payload

    enum Payload: Codable, Sendable {
        case observationBatch([WireObservation])
        case wristSweep(WristSweep)
        case altitude(AltitudeReading)
        case guidance(GuidanceCommand)
        case tierCommand(tier: Int)
        case targetFocus(targetID: String?, label: String?)
        case discoveryToken(Data)          // NIDiscoveryToken, archived
        case clockPing(id: UUID)
        case clockPong(id: UUID, receivedAtNanos: UInt64, repliedAtNanos: UInt64)
        case nodeStatus(NodeStatus)
    }
}

/// Sendable projection of RFObservation. The Watch does not link the fusion engine —
/// it produces observations and ships them; all estimation happens on the A18 Pro.
struct WireObservation: Codable, Sendable {
    var targetID: String
    var modality: String              // RFObservation.Modality.rawValue
    var at: Date
    var observerPosition: [Double]    // 3
    var observerHeading: Double?
    var range: Double?
    var rangeSigma: Double?
    var direction: [Float]?           // 3
    var directionSigma: Double?
    var scalar: Double?
    var qualitative: String?
    var sourceRole: NodeRole
}

/// THE WRIST SWEEP — the highest-value thing the Watch can do that the phone cannot.
///
/// A BLE radio is omnidirectional. A human arm and torso are not: body tissue attenuates
/// 2.4 GHz by roughly 10-20 dB. Sweeping the wrist through an arc therefore modulates RSSI
/// as a function of wrist heading, and the maximum points at the transmitter. The operator's
/// own body is the directional element.
///
/// This gives a coarse bearing (±30-40°) from hardware with no directional capability at all,
/// on any BLE device, with no UWB and no cooperating peer. It is the poor man's phased array.
struct WristSweep: Codable, Sendable {
    struct Sample: Codable, Sendable {
        var heading: Double           // radians, true north, from CMDeviceMotion
        var pitch: Double
        var roll: Double
        var rssi: Int
        var at: Date
    }
    var targetID: String
    var samples: [Sample]
    var startedAt: Date
    var endedAt: Date

    /// Circular-weighted mean of the top-quartile samples. Returns bearing and a concentration
    /// parameter — low concentration means the sweep was too fast, too short, or the target is
    /// behind a wall and the shadow pattern is meaningless. Never emit a bearing without it.
    func resolveBearing() -> (bearing: Double, concentration: Double, sampleCount: Int)? {
        guard samples.count >= 24 else { return nil }
        let sorted = samples.sorted { $0.rssi > $1.rssi }
        let top = sorted.prefix(max(6, samples.count / 4))
        // Weight by RSSI above the sweep floor so the strongest lobe dominates.
        let floorRSSI = Double(sorted.last?.rssi ?? -100)
        var sx = 0.0, sy = 0.0, wsum = 0.0
        for s in top {
            let w = max(Double(s.rssi) - floorRSSI, 0.1)
            sx += w * sin(s.heading); sy += w * cos(s.heading); wsum += w
        }
        guard wsum > 0 else { return nil }
        let r = (sx*sx + sy*sy).squareRoot() / wsum       // 0 = uniform, 1 = perfectly peaked
        return (atan2(sx, sy), r, samples.count)
    }

    /// Dynamic range of the sweep. Below ~6 dB the body shadow never developed and the
    /// bearing is noise — usually means the target is very close (saturated) or very far.
    var dynamicRangeDB: Int {
        guard let hi = samples.map(\.rssi).max(), let lo = samples.map(\.rssi).min() else { return 0 }
        return hi - lo
    }
}

/// Two barometers at different heights on one body. The absolute reading of either drifts with
/// weather; the DIFFERENCE does not. Subtracting them cancels ambient pressure change entirely,
/// which is what makes floor discrimination reliable over a long session instead of good for
/// twenty minutes.
struct AltitudeReading: Codable, Sendable {
    var relativeAltitude: Double      // metres from that node's session origin
    var pressureKPa: Double
    var at: Date
    var role: NodeRole
}

struct GuidanceCommand: Codable, Sendable {
    var targetID: String
    var label: String
    var bearing: Double?              // radians relative to true north
    var distance: Double?             // metres
    var radius95: Double?             // metres, uncertainty
    var confidence: Double
    var floorDelta: Int?
    var hapticPattern: HapticPattern
    enum HapticPattern: String, Codable, Sendable, CaseIterable {
        case silent, searching, warmer, colder, close, arrived, lost, wrongFloor
    }
}

struct NodeStatus: Codable, Sendable {
    var role: NodeRole
    var battery: Double               // 0-1
    var isCharging: Bool
    var bluetoothScanning: Bool
    var uwbAvailable: Bool
    var extendedRuntimeActive: Bool
    var thermalState: Int             // ProcessInfo.ThermalState.rawValue
    var at: Date
}
