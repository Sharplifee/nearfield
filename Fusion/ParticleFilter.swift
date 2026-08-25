import Foundation
import simd

/// Sequential Monte Carlo localisation.
///
/// Chosen over EKF deliberately: BLE RSSI likelihood is non-Gaussian and heavily multipath-skewed,
/// and the search problem is multi-modal — a device 5 m away through a wall and 12 m away down a
/// corridor produce the same RSSI. A Kalman filter collapses that to a confident wrong answer.
/// Particles keep both hypotheses alive until a UWB range, a floor change, or operator motion kills one.
///
/// This is the component the dissected target does not have and cannot bolt on: it has one modality
/// and renders it as a bar.
actor ParticleFilter {

    struct Particle { var position: SIMD3<Double>; var weight: Double }

    private var particles: [Particle] = []
    private let count: Int
    private var lastUpdate: Date
    private let targetID: String

    /// Log-distance path loss model. n varies 1.6 (corridor waveguide) to 4.0 (through walls).
    /// Estimated online from the spread of residuals rather than hardcoded.
    private var pathLossExponent: Double = 2.6
    private var referenceRSSI: Double = -59   // dBm at 1 m

    init(targetID: String, count: Int = 2000, bounds: Double = 60) {
        self.targetID = targetID
        self.count = count
        self.lastUpdate = .now
        // Uniform prior over a sphere of radius `bounds` — no assumption about where it is.
        particles = (0..<count).map { _ in
            Particle(position: SIMD3(.random(in: -bounds...bounds),
                                     .random(in: -bounds...bounds),
                                     .random(in: -6...6)),   // +/- 2 floors
                     weight: 1.0 / Double(count))
        }
    }

    /// Diffusion step. Static targets still need process noise or the filter becomes overconfident
    /// and cannot recover when the operator's own position estimate drifts.
    func predict(processNoise sigma: Double = 0.15, dt: TimeInterval) {
        let s = sigma * max(dt, 0.1)
        for i in particles.indices {
            particles[i].position += SIMD3(.random(in: -s...s), .random(in: -s...s), .random(in: -s/4...s/4))
        }
    }

    func update(with observation: RFObservation) {
        guard observation.targetID == targetID else { return }
        let dt = observation.at.timeIntervalSince(lastUpdate)
        predict(dt: dt)
        lastUpdate = observation.at

        for i in particles.indices {
            particles[i].weight *= likelihood(of: observation, given: particles[i].position)
        }
        normalise()
        if effectiveSampleSize() < Double(count) / 2 { resample() }
    }

    private func likelihood(of obs: RFObservation, given p: SIMD3<Double>) -> Double {
        let d = simd_distance(p, obs.observerPosition)
        switch obs.modality {

        case .uwbDistance, .acousticToF, .iBeaconRange:
            guard let r = obs.range else { return 1 }
            let sigma = obs.rangeSigma ?? RFObservation.defaultSigma(obs.modality)
            return gaussian(d - r, sigma)

        case .bleRSSI:
            // Convert particle distance to expected RSSI and compare in dB space, not metre space.
            // Comparing in metres after an exponential inversion inflates far-field error enormously —
            // this is why naive RSSI trilateration fails past ~8 m.
            guard let rssi = obs.scalar else { return 1 }
            let expected = referenceRSSI - 10 * pathLossExponent * log10(max(d, 0.3))
            return gaussian(expected - rssi, 6.0)

        case .uwbDirection:
            guard let dir = obs.direction else { return 1 }
            let toParticle = simd_normalize(SIMD3<Float>(p - obs.observerPosition))
            let cosAngle = Double(simd_dot(simd_normalize(dir), toParticle))
            let angle = acos(min(max(cosAngle, -1), 1))
            return gaussian(angle, obs.directionSigma ?? 0.175)   // ~10 deg

        case .barometricFloor:
            // Vertical constraint only. Leaves x/y untouched — exactly the kind of partial
            // observation a particle filter absorbs for free and an EKF needs special-casing for.
            guard let alt = obs.scalar else { return 1 }
            return gaussian(p.z - alt, 1.0)

        case .magneticAnomaly:
            // Qualitative: anomaly implies proximity. Weak, wide likelihood, never decisive alone.
            guard let strength = obs.scalar, strength > 5 else { return 1 }
            return gaussian(d, 3.0) * 0.5 + 0.5

        case .wifiBSSID, .bonjourPresence, .threadPresence:
            // Presence constraints: bound the search volume, do not shape it.
            return d < 40 ? 1.0 : 0.2
        }
    }

    private func gaussian(_ error: Double, _ sigma: Double) -> Double {
        guard sigma.isFinite, sigma > 0 else { return 1 }
        return exp(-(error * error) / (2 * sigma * sigma)) + 1e-9   // floor prevents particle death
    }

    private func normalise() {
        let total = particles.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return }
        for i in particles.indices { particles[i].weight /= total }
    }

    private func effectiveSampleSize() -> Double {
        1.0 / particles.reduce(0) { $0 + $1.weight * $1.weight }
    }

    /// Low-variance systematic resampling — O(n), no sorting, preserves diversity better than
    /// multinomial. Standard Thrun/Burgard formulation.
    private func resample() {
        var new: [Particle] = []
        new.reserveCapacity(count)
        let step = 1.0 / Double(count)
        var r = Double.random(in: 0..<step)
        var c = particles[0].weight
        var i = 0
        for _ in 0..<count {
            while r > c, i < particles.count - 1 { i += 1; c += particles[i].weight }
            new.append(Particle(position: particles[i].position, weight: step))
            r += step
        }
        particles = new
    }

    func estimate() -> PositionEstimate {
        let mean = particles.reduce(SIMD3<Double>.zero) { $0 + $1.position * $1.weight }
        var cov = simd_double3x3(0)
        for p in particles {
            let d = p.position - mean
            cov += simd_double3x3(SIMD3(d.x*d.x, d.x*d.y, d.x*d.z),
                                  SIMD3(d.y*d.x, d.y*d.y, d.y*d.z),
                                  SIMD3(d.z*d.x, d.z*d.y, d.z*d.z)) * p.weight
        }
        return PositionEstimate(targetID: targetID, mean: mean, covariance: cov,
                                confidence: effectiveSampleSize() / Double(count),
                                floorDelta: Int((mean.z / 3.0).rounded()),
                                contributingModalities: [], at: .now)
    }

    /// Online path-loss estimation. Recovers the environment class (open floor vs. through-wall)
    /// from residuals once at least one metric-truth modality has constrained the solution.
    func calibratePathLoss(from pairs: [(distance: Double, rssi: Double)]) {
        guard pairs.count >= 8 else { return }
        let xs = pairs.map { log10(max($0.distance, 0.3)) }
        let ys = pairs.map { $0.rssi }
        let mx = xs.reduce(0,+) / Double(xs.count), my = ys.reduce(0,+) / Double(ys.count)
        let num = zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) }
        let den = xs.reduce(0) { $0 + pow($1 - mx, 2) }
        guard den > 0 else { return }
        let slope = num / den                       // = -10n
        pathLossExponent = min(max(-slope / 10, 1.6), 4.5)
        referenceRSSI = my - slope * mx
    }
}
