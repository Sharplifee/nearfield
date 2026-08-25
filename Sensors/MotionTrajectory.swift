import Foundation
import CoreMotion
import simd

/// The observer's own position. Without this every RSSI sample is taken from an unknown point
/// and trilateration is impossible — which is precisely why the target can only render a bar.
///
/// Three independent sources, degraded gracefully:
///   1. ARKit world tracking (cm-accurate, foreground, camera) — see Spatial/ARFieldMapper
///   2. Pedestrian dead reckoning (this file) — background-capable, drifts ~2% of distance
///   3. Core Location (metres, outdoor only)
@Observable
@MainActor
final class MotionTrajectory {

    private let motion = CMMotionManager()
    private let pedometer = CMPedometer()
    private let altimeter = CMAltimeter()

    private(set) var position: SIMD3<Double> = .zero      // session frame, metres
    private(set) var heading: Double = 0                  // radians
    private(set) var relativeAltitude: Double = 0         // metres from session start
    private(set) var pressureKPa: Double?
    private(set) var stepLength: Double = 0.72            // metres, calibrated from pedometer
    private(set) var magneticAnomaly: Double = 0          // uT deviation from local baseline

    private var magneticBaseline: Double?
    private var lastStepCount: Int = 0

    func start() {
        startDeviceMotion()
        startPedometer()
        startAltimeter()
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        motion.stopMagnetometerUpdates()
        pedometer.stopUpdates()
        altimeter.stopRelativeAltitudeUpdates()
    }

    private func startDeviceMotion() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 50
        // xTrueNorth requires location authorisation; falls back to magnetic silently otherwise.
        motion.startDeviceMotionUpdates(using: .xTrueNorthZVertical, to: .main) { [weak self] dm, _ in
            guard let self, let dm else { return }
            self.heading = dm.heading * .pi / 180

            // Magnetic anomaly: deviation of total field magnitude from a rolling baseline.
            // Ferrous mass and energised electronics both perturb it — useful as a final-metre cue
            // when RSSI has saturated and UWB is unavailable.
            let f = dm.magneticField.field
            let magnitude = sqrt(f.x*f.x + f.y*f.y + f.z*f.z)
            if dm.magneticField.accuracy != .uncalibrated {
                if let base = self.magneticBaseline {
                    self.magneticBaseline = base * 0.995 + magnitude * 0.005
                    self.magneticAnomaly = abs(magnitude - base)
                } else { self.magneticBaseline = magnitude }
            }
        }
    }

    /// Step-based dead reckoning. Integrating accelerometer directly drifts cubically and is
    /// useless past ~10 seconds; step events are quantised and bounded, so error grows linearly.
    private func startPedometer() {
        guard CMPedometer.isStepCountingAvailable() else { return }
        pedometer.startUpdates(from: .now) { [weak self] data, _ in
            guard let self, let data else { return }
            Task { @MainActor in
                let steps = data.numberOfSteps.intValue
                let delta = steps - self.lastStepCount
                self.lastStepCount = steps
                guard delta > 0 else { return }
                // Calibrate stride from the pedometer's own distance estimate when available.
                if let distance = data.distance?.doubleValue, steps > 20 {
                    self.stepLength = min(max(distance / Double(steps), 0.4), 0.95)
                }
                let advance = Double(delta) * self.stepLength
                self.position += SIMD3(advance * sin(self.heading), advance * cos(self.heading), 0)
            }
        }
    }

    /// Barometric floor discrimination. This is the highest-value under-used sensor on iOS:
    /// ~1 m vertical resolution means you can tell a device is one floor up, which no amount of
    /// RSSI will ever tell you. The target has none of this.
    private func startAltimeter() {
        guard CMAltimeter.isRelativeAltitudeAvailable() else { return }
        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
            guard let self, let data else { return }
            self.relativeAltitude = data.relativeAltitude.doubleValue
            self.pressureKPa = data.pressure.doubleValue
            self.position.z = self.relativeAltitude
        }
    }

    /// Absolute altitude (iOS 15+, barometer + GNSS fusion) where available.
    func startAbsoluteAltitude(_ handler: @escaping @Sendable (Double, Double) -> Void) {
        guard CMAltimeter.isAbsoluteAltitudeAvailable() else { return }
        altimeter.startAbsoluteAltitudeUpdates(to: .main) { data, _ in
            guard let data else { return }
            handler(data.altitude, data.accuracy)
        }
    }

    func resetOrigin() { position = .zero; relativeAltitude = 0; magneticBaseline = nil }
}
