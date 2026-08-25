import Foundation
import simd

/// Every sensor in the mesh reduces to one of these. The fusion engine consumes only this type,
/// which is what lets UWB, BLE RSSI, iBeacon, acoustic ToF and Wi-Fi fingerprints be added,
/// removed, or degraded independently without touching the estimator.
struct RFObservation: Sendable, Identifiable {
    enum Modality: String, Sendable, CaseIterable {
        case bleRSSI          // sigma ~ 4-8 m indoors. Always available.
        case iBeaconRange     // sigma ~ 1-3 m. Free on any 0x02 broadcaster.
        case uwbDistance      // sigma ~ 0.10 m. Cooperating peers/accessories only.
        case uwbDirection     // sigma ~ 10 deg. iPhone 11+ with camera assistance.
        case acousticToF      // sigma ~ 0.3 m. Own devices, line of sight, <10 m.
        case wifiBSSID        // room-level. Fingerprint, not range.
        case barometricFloor  // +/- 1 m vertical. Floor discrimination.
        case magneticAnomaly  // proximity to ferrous mass. Qualitative.
        case bonjourPresence  // binary same-subnet presence.
        case threadPresence   // binary 802.15.4 mesh membership.
    }

    let id = UUID()
    var targetID: String              // peripheral UUID, accessory ID, or beacon identity
    var modality: Modality
    var at: Date

    /// Observer pose in the session frame at the moment of observation.
    var observerPosition: SIMD3<Double>
    var observerHeading: Double?      // radians, true north

    var range: Double?                // metres
    var rangeSigma: Double?           // metres, 1 sigma — NEVER a point estimate without this
    var direction: SIMD3<Float>?      // unit vector, observer frame
    var directionSigma: Double?       // radians
    var scalar: Double?               // RSSI dBm, altitude m, field strength uT
    var qualitative: String?          // BSSID, service name, mesh ID

    /// Modality-appropriate default uncertainty. Real sigma should come from the sensor.
    static func defaultSigma(_ m: Modality) -> Double {
        switch m {
        case .uwbDistance:     0.10
        case .acousticToF:     0.30
        case .iBeaconRange:    2.00
        case .bleRSSI:         6.00
        case .barometricFloor: 1.00
        default:               .infinity
        }
    }
}

/// Output of the estimator. Always an ellipsoid, never a pin.
struct PositionEstimate: Sendable {
    var targetID: String
    var mean: SIMD3<Double>
    var covariance: simd_double3x3
    var confidence: Double            // 0-1, effective sample size ratio
    var floorDelta: Int?              // relative floors from session origin
    var contributingModalities: Set<RFObservation.Modality>
    var at: Date

    /// 95% horizontal radius. This is what the UI renders — a circle that shrinks as you close in.
    var horizontalRadius95: Double {
        let sx = covariance[0][0], sy = covariance[1][1]
        return 2.4477 * (sx + sy).squareRoot() / 2
    }
}
