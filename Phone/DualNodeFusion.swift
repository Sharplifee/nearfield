import Foundation
import simd
import Observation

/// Phone-side fusion of the two-node system. Extends SensorMesh rather than replacing it.
///
/// FOUR THINGS TWO NODES BUY YOU THAT ONE CANNOT:
///
///  1. DECORRELATED OBSERVATIONS. A single walking operator produces highly correlated RSSI
///     error — same body, same orientation, same multipath geometry. Wrist and pocket are
///     ~0.6-0.9 m apart with different body shadowing, so their errors are largely independent.
///     Independent errors are what actually make a particle filter converge indoors.
///
///  2. DIFFERENTIAL BAROMETRY. Two barometers on one body. Absolute readings both drift with
///     weather; the difference does not. Subtracting cancels ambient pressure change entirely,
///     turning floor detection from "reliable for twenty minutes" into "reliable all day".
///
///  3. WRIST SWEEP BEARING. Body shadowing makes the operator into a directional element.
///     A coarse bearing on ANY BLE device, with no UWB and no cooperating hardware.
///
///  4. INSTANT LEFT/RIGHT. When phone and Watch see the same device simultaneously and the
///     phone knows which wrist and which pocket, the sign of the RSSI difference is a
///     lateral discriminator available every single advertisement, with zero user action.
@Observable
@MainActor
final class DualNodeFusion {

    /// Body baseline between pocket/hand phone and wrist Watch. Calibrated, not assumed.
    private(set) var bodyBaseline: Double = 0.75          // metres
    private(set) var watchOnLeftWrist = true
    private(set) var altitudeOffset: Double = 0           // watch - phone, metres
    private(set) var lateralBias: Double = 0              // running mean of RSSI delta, dB

    private let mesh: SensorMesh
    private let link: DeviceLink
    private var phoneAltitudes: [(Date, Double)] = []
    private var watchAltitudes: [(Date, Double)] = []
    private var rssiPairs: [(phone: Int, watch: Int, at: Date)] = []

    init(mesh: SensorMesh, link: DeviceLink) {
        self.mesh = mesh
        self.link = link
        link.onMessage = { [weak self] message in
            Task { @MainActor in self?.handle(message) }
        }
    }

    private func handle(_ message: NodeMessage) {
        switch message.payload {
        case let .observationBatch(batch):
            for wire in batch { ingest(wire) }
        case let .wristSweep(sweep):
            ingest(sweep)
        case let .altitude(reading):
            watchAltitudes.append((reading.at, reading.relativeAltitude))
            if watchAltitudes.count > 300 { watchAltitudes.removeFirst() }
            recomputeAltitudeOffset()
        default: break
        }
    }

    // MARK: 1 — decorrelated observations

    private func ingest(_ wire: WireObservation) {
        guard let modality = RFObservation.Modality(rawValue: wire.modality) else { return }

        // Offset the Watch's observer position by the body baseline in the heading direction.
        // Treating both nodes as co-located throws away the entire geometric advantage.
        let phonePose = mesh.ar.isTracking ? mesh.ar.pose : mesh.motion.position
        let lateral = watchOnLeftWrist ? -bodyBaseline / 2 : bodyBaseline / 2
        let heading = wire.observerHeading ?? mesh.motion.heading
        let watchPose = phonePose + SIMD3(lateral * cos(heading), -lateral * sin(heading),
                                          altitudeOffset)

        var observation = RFObservation(
            targetID: wire.targetID, modality: modality, at: wire.at,
            observerPosition: watchPose, observerHeading: wire.observerHeading,
            range: wire.range, rangeSigma: wire.rangeSigma,
            direction: wire.direction.map { SIMD3($0[0], $0[1], $0[2]) },
            directionSigma: wire.directionSigma,
            scalar: wire.scalar, qualitative: wire.qualitative)

        // Watch RSSI is systematically weaker: smaller antenna, wrist against the body.
        // Correct the bias rather than letting the path-loss estimator absorb it as environment.
        if modality == .bleRSSI, let rssi = observation.scalar {
            observation.scalar = rssi - lateralBias
        }
        mesh.ingest(observation)
        recordPair(wire)
    }

    // MARK: 2 — differential barometry

    func recordPhoneAltitude(_ metres: Double, at date: Date = .now) {
        phoneAltitudes.append((date, metres))
        if phoneAltitudes.count > 300 { phoneAltitudes.removeFirst() }
        recomputeAltitudeOffset()
    }

    /// Weather changes pressure at both sensors identically. Differencing removes it entirely.
    /// What remains is the true vertical separation of wrist and pocket — a constant on one body,
    /// so any sustained CHANGE in the difference is a real vertical movement, not weather.
    private func recomputeAltitudeOffset() {
        guard phoneAltitudes.count > 10, watchAltitudes.count > 10 else { return }
        var deltas: [Double] = []
        for (t, watchAlt) in watchAltitudes.suffix(60) {
            guard let nearest = phoneAltitudes.min(by: {
                abs($0.0.timeIntervalSince(t)) < abs($1.0.timeIntervalSince(t))
            }), abs(nearest.0.timeIntervalSince(t)) < 2 else { continue }
            deltas.append(watchAlt - nearest.1)
        }
        guard deltas.count >= 8 else { return }
        // Median, not mean — arm raises produce large transient outliers.
        altitudeOffset = deltas.sorted()[deltas.count / 2]
    }

    /// Floor estimate that survives a weather front. Uses the differenced signal, then applies
    /// a hysteresis band so a stairwell landing does not flicker between floors.
    private var committedFloor = 0
    func floorDelta(storeyHeight: Double = 3.0) -> Int {
        let raw = mesh.motion.relativeAltitude / storeyHeight
        let candidate = Int(raw.rounded())
        if abs(raw - Double(committedFloor)) > 0.65 { committedFloor = candidate }
        return committedFloor
    }

    // MARK: 3 — wrist sweep bearing

    private func ingest(_ sweep: WristSweep) {
        // Below ~6 dB dynamic range the body shadow never developed. Discard rather than fuse
        // a bearing that is pure noise — a confident wrong arrow is worse than no arrow.
        guard sweep.dynamicRangeDB >= 6,
              let resolved = sweep.resolveBearing(),
              resolved.concentration > 0.35 else { return }

        // Concentration maps to angular sigma. r=1 is perfectly peaked, r=0.35 is barely usable.
        let sigma = max(0.20, (1.0 - resolved.concentration) * 1.2)   // radians
        let pose = mesh.ar.isTracking ? mesh.ar.pose : mesh.motion.position
        let unit = SIMD3<Float>(Float(sin(resolved.bearing)), Float(cos(resolved.bearing)), 0)

        mesh.ingest(RFObservation(
            targetID: sweep.targetID, modality: .uwbDirection, at: sweep.endedAt,
            observerPosition: pose, observerHeading: resolved.bearing,
            direction: unit, directionSigma: sigma))
    }

    // MARK: 4 — instant lateral discrimination

    private func recordPair(_ wire: WireObservation) {
        guard wire.modality == "bleRSSI", let watchRSSI = wire.scalar else { return }
        guard let phoneRSSI = mesh.estimates[wire.targetID] != nil ? lastPhoneRSSI[wire.targetID] : nil
        else { return }
        rssiPairs.append((phoneRSSI, Int(watchRSSI), wire.at))
        if rssiPairs.count > 200 { rssiPairs.removeFirst() }
        // Running bias: the mean difference over all targets is the antenna/body offset,
        // not information about any one device. Subtract it so the residual IS information.
        let mean = Double(rssiPairs.reduce(0) { $0 + ($1.watch - $1.phone) }) / Double(rssiPairs.count)
        lateralBias = mean
    }

    private var lastPhoneRSSI: [String: Int] = [:]
    func notePhoneRSSI(targetID: String, rssi: Int) { lastPhoneRSSI[targetID] = rssi }

    /// Sign of the bias-corrected difference. Positive means the target is on the Watch side.
    /// Available every advertisement, no user action, no UWB. Coarse but instant.
    func lateralHint(targetID: String, watchRSSI: Int) -> String? {
        guard let phoneRSSI = lastPhoneRSSI[targetID] else { return nil }
        let delta = Double(watchRSSI - phoneRSSI) - lateralBias
        guard abs(delta) > 3 else { return nil }        // below 3 dB is noise
        let watchSide = watchOnLeftWrist ? "left" : "right"
        let otherSide = watchOnLeftWrist ? "right" : "left"
        return delta > 0 ? watchSide : otherSide
    }

    // MARK: Guidance uplink

    /// Push guidance to the wrist. Called on the estimator's update cadence, throttled —
    /// pushing every particle-filter iteration will flatten the Watch battery in an hour.
    private var lastPush: Date = .distantPast
    func pushGuidance(targetID: String, label: String, minimumInterval: TimeInterval = 1.0) {
        guard Date.now.timeIntervalSince(lastPush) > minimumInterval else { return }
        lastPush = .now

        guard let g = mesh.guidance(for: targetID) else {
            link.send(.guidance(GuidanceCommand(targetID: targetID, label: label,
                                                bearing: nil, distance: nil, radius95: nil,
                                                confidence: 0, floorDelta: nil,
                                                hapticPattern: .searching)), urgent: true)
            return
        }
        let floor = floorDelta()
        let pattern: GuidanceCommand.HapticPattern =
            floor != 0 ? .wrongFloor :
            g.distance < 0.6 ? .arrived :
            g.distance < 3 ? .close : .warmer

        link.send(.guidance(GuidanceCommand(
            targetID: targetID, label: label,
            bearing: g.bearing, distance: g.distance, radius95: g.radius,
            confidence: mesh.estimates[targetID]?.confidence ?? 0,
            floorDelta: floor, hapticPattern: pattern)), urgent: true)
    }

    // MARK: Calibration

    /// One-time body baseline calibration. Operator holds phone and touches it to the Watch,
    /// then extends the arm fully. The RSSI delta swing across that motion, plus the known
    /// arm length range, pins the effective baseline without asking the user to measure anything.
    func calibrateBaseline(touchingDelta: Double, extendedDelta: Double) {
        let swing = abs(extendedDelta - touchingDelta)
        guard swing > 4 else { return }         // insufficient contrast, keep the default
        bodyBaseline = min(max(0.4 + swing * 0.04, 0.4), 1.0)
    }

    func setWatchWrist(left: Bool) { watchOnLeftWrist = left }
}
