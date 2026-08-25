import Foundation
import Combine
import simd

/// The orchestrator. Every sensor is optional and independently degradable; the mesh decides
/// which modalities are live, arbitrates duty cycle against battery, and feeds one observation
/// stream into the fusion engine.
///
/// DUTY CYCLE IS THE REAL DESIGN CONSTRAINT. Running BLE wildcard scan + UWB + ARKit + audio
/// simultaneously drains an iPhone in under 90 minutes. The mesh runs a tier ladder:
///   IDLE      — BLE service-filtered background only
///   TRACKING  — + iBeacon ranging + motion/altimeter
///   HUNTING   — + UWB where available + acoustic
///   PRECISION — + ARKit world tracking, foreground, hard 10-minute cap
@Observable
@MainActor
final class SensorMesh {

    enum Tier: Int, Comparable, CaseIterable {
        case idle, tracking, hunting, precision
        static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }
        var label: String {
            switch self {
            case .idle: "Idle"; case .tracking: "Tracking"
            case .hunting: "Hunting"; case .precision: "Precision"
            }
        }
        var estimatedDrainPerHour: Double {   // percent, iPhone 15 Pro class
            switch self { case .idle: 2; case .tracking: 7; case .hunting: 16; case .precision: 34 }
        }
    }

    private(set) var tier: Tier = .idle
    private(set) var activeModalities: Set<RFObservation.Modality> = []
    private(set) var estimates: [String: PositionEstimate] = [:]

    private let central: BluetoothCentral
    let motion = MotionTrajectory()
    let uwb = UWBRanging()
    let beacons = BeaconRanging()
    let network = NetworkPresence()
    let acoustic = AcousticRanging()
    let ar = ARFieldMapper()

    private var filters: [String: ParticleFilter] = [:]
    private var precisionDeadline: Date?

    init(central: BluetoothCentral) {
        self.central = central
        wireObservationSources()
    }

    private func wireObservationSources() {
        let pose: () -> SIMD3<Double> = { [weak self] in
            guard let self else { return .zero }
            // ARKit pose wins when tracking; dead reckoning otherwise. The estimator is agnostic.
            return self.ar.isTracking ? self.ar.pose : self.motion.position
        }
        uwb.observerPose = pose
        beacons.observerPose = pose
        acoustic.observerPose = pose

        uwb.onObservation = { [weak self] in self?.ingest($0) }
        beacons.onObservation = { [weak self] in self?.ingest($0) }
        acoustic.onObservation = { [weak self] in self?.ingest($0) }
    }

    func ingest(_ observation: RFObservation) {
        activeModalities.insert(observation.modality)
        let filter = filters[observation.targetID] ?? {
            let f = ParticleFilter(targetID: observation.targetID)
            filters[observation.targetID] = f
            return f
        }()
        Task {
            await filter.update(with: observation)
            let estimate = await filter.estimate()
            await MainActor.run { self.estimates[observation.targetID] = estimate }
        }
    }

    /// Feed a raw BLE RSSI reading in. Called from ScanIngest's flush.
    func ingestRSSI(targetID: String, rssi: Int) {
        guard SignalCalibration.isValid(rssi) else { return }
        ingest(RFObservation(targetID: targetID, modality: .bleRSSI, at: .now,
                             observerPosition: ar.isTracking ? ar.pose : motion.position,
                             observerHeading: motion.heading,
                             scalar: Double(rssi)))
        if ar.isTracking { ar.record(targetID: targetID, rssi: rssi) }
        // Vertical constraint is free once the altimeter is running.
        ingest(RFObservation(targetID: targetID, modality: .barometricFloor, at: .now,
                             observerPosition: motion.position, observerHeading: nil,
                             scalar: motion.relativeAltitude))
    }

    func escalate(to newTier: Tier) {
        guard newTier != tier else { return }
        // Tear down above the new tier first, then build up. Order prevents radio contention:
        // UWB and Wi-Fi share the 2.4/5 GHz front end on some SoCs and interleave badly.
        if newTier < .precision { ar.stop() }
        if newTier < .hunting { acoustic.stop(); uwb.stop("all") }

        switch newTier {
        case .idle:
            motion.stop()
            central.start(.background)
        case .tracking:
            motion.start()
            beacons.requestAuthorization()
            central.start(.foregroundAll)
            network.startBrowsing()
        case .hunting:
            motion.start()
            central.start(.foregroundAll)
            try? acoustic.start()
        case .precision:
            motion.start()
            central.start(.foregroundAll)
            ar.start()
            precisionDeadline = .now.addingTimeInterval(600)   // hard cap, thermal + battery
        }
        tier = newTier
    }

    /// Call on a timer. Auto-demotes out of precision and out of hunting when the target's
    /// uncertainty has already collapsed — no reason to burn battery once the ellipse is small.
    func reviewTier(now: Date = .now) {
        if tier == .precision, let deadline = precisionDeadline, now > deadline {
            escalate(to: .hunting)
        }
        if tier >= .hunting,
           let best = estimates.values.min(by: { $0.horizontalRadius95 < $1.horizontalRadius95 }),
           best.horizontalRadius95 < 0.5, best.confidence > 0.6 {
            escalate(to: .tracking)
        }
    }

    /// Bearing and distance to render as an arrow. Nil when the estimate is too diffuse to point.
    func guidance(for targetID: String) -> (bearing: Double, distance: Double, radius: Double)? {
        guard let e = estimates[targetID], e.horizontalRadius95 < 25, e.confidence > 0.25 else { return nil }
        let here = ar.isTracking ? ar.pose : motion.position
        let delta = e.mean - here
        let distance = simd_length(delta)
        guard distance > 0.1 else { return nil }
        let bearing = atan2(delta.x, delta.y) - motion.heading
        return (bearing, distance, e.horizontalRadius95)
    }
}
