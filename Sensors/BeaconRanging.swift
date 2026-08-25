import Foundation
import CoreLocation

/// FREE RANGING THE TARGET LEAVES ON THE TABLE.
///
/// Any device broadcasting Apple continuity type 0x02 is an iBeacon. CoreLocation will range it
/// with a calibrated, Apple-tuned RSSI model that is materially better than raw RSSI — it applies
/// its own filtering and returns `accuracy` in metres plus a coarse proximity class.
///
/// The target decodes 0x02 as a label and stops. We decode it, extract UUID/major/minor, and
/// hand it straight to CoreLocation for metric ranging. Zero extra hardware.
@Observable
@MainActor
final class BeaconRanging: NSObject, CLLocationManagerDelegate {

    private let manager = CLLocationManager()
    private var constraints: [UUID: CLBeaconIdentityConstraint] = [:]
    private var monitor: CLMonitor?

    var onObservation: (@MainActor (RFObservation) -> Void)?
    var observerPose: () -> SIMD3<Double> = { .zero }
    private(set) var authorization: CLAuthorizationStatus = .notDetermined

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
    }

    func requestAuthorization() { manager.requestAlwaysAuthorization() }

    /// Extract an iBeacon identity from a decoded continuity message of type 0x02.
    /// Payload: [16 byte proximity UUID][2 byte major BE][2 byte minor BE][1 byte measured power]
    static func beaconIdentity(from message: ContinuityMessage) -> (uuid: UUID, major: UInt16, minor: UInt16, power: Int8)? {
        guard message.type == 0x02, message.payload.count >= 21 else { return nil }
        let bytes = [UInt8](message.payload)
        let uuidBytes = Array(bytes[0..<16])
        let uuid = UUID(uuid: (uuidBytes[0], uuidBytes[1], uuidBytes[2], uuidBytes[3],
                               uuidBytes[4], uuidBytes[5], uuidBytes[6], uuidBytes[7],
                               uuidBytes[8], uuidBytes[9], uuidBytes[10], uuidBytes[11],
                               uuidBytes[12], uuidBytes[13], uuidBytes[14], uuidBytes[15]))
        let major = UInt16(bytes[16]) << 8 | UInt16(bytes[17])
        let minor = UInt16(bytes[18]) << 8 | UInt16(bytes[19])
        return (uuid, major, minor, Int8(bitPattern: bytes[20]))
    }

    func range(uuid: UUID, major: UInt16? = nil, minor: UInt16? = nil) {
        let constraint: CLBeaconIdentityConstraint
        switch (major, minor) {
        case let (m?, n?): constraint = CLBeaconIdentityConstraint(uuid: uuid, major: m, minor: n)
        case let (m?, nil): constraint = CLBeaconIdentityConstraint(uuid: uuid, major: m)
        default:            constraint = CLBeaconIdentityConstraint(uuid: uuid)
        }
        constraints[uuid] = constraint
        manager.startRangingBeacons(satisfying: constraint)
    }

    func stopRanging(uuid: UUID) {
        guard let c = constraints.removeValue(forKey: uuid) else { return }
        manager.stopRangingBeacons(satisfying: c)
    }

    /// CLMonitor (iOS 17+) replaces the old region API and survives termination.
    /// A beacon condition here is what wakes the app when a tracked sensor comes back into range —
    /// the third leg of background persistence alongside BLE restoration and the audio session.
    func beginMonitoring(name: String, uuid: UUID) async {
        if monitor == nil { monitor = await CLMonitor("NearfieldMonitor") }
        await monitor?.add(CLMonitor.BeaconIdentityCondition(uuid: uuid), identifier: name)
    }

    nonisolated func locationManager(_ m: CLLocationManager, didRange beacons: [CLBeacon],
                                     satisfying constraint: CLBeaconIdentityConstraint) {
        let snapshot = beacons.map { ($0.uuid, $0.major.intValue, $0.minor.intValue, $0.accuracy, $0.rssi, $0.proximity) }
        Task { @MainActor in self.handleRanged(snapshot) }
    }

    private func handleRanged(_ beacons: [(UUID, Int, Int, Double, Int, CLProximity)]) {
        let pose = observerPose()
        for (uuid, major, minor, accuracy, rssi, proximity) in beacons {
            // accuracy < 0 means the estimate is unreliable — Apple's own signal, honour it.
            guard accuracy > 0 else { continue }
            onObservation?(RFObservation(
                targetID: "\(uuid.uuidString):\(major):\(minor)",
                modality: .iBeaconRange, at: .now,
                observerPosition: pose, observerHeading: nil,
                range: accuracy,
                // Apple's accuracy is roughly a 1-sigma metre estimate; widen with proximity class.
                rangeSigma: proximity == .immediate ? 0.5 : (proximity == .near ? 1.5 : 4.0),
                scalar: Double(rssi)))
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        let status = m.authorizationStatus
        Task { @MainActor in self.authorization = status }
    }
}
