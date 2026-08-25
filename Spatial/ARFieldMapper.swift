import Foundation
import ARKit
import simd

/// Room-scale RF field mapping.
///
/// ARKit world tracking gives centimetre-accurate 6DoF pose — an order of magnitude better than
/// pedestrian dead reckoning. Every RSSI sample taken while a session is running gets an exact
/// 3D coordinate, which converts a scalar time series into a spatial field you can render and
/// gradient-descend. That is the difference between "the bar got bigger" and "it is behind you
/// and to the left, 2.4 m, one metre up."
///
/// Foreground and camera only. Falls back to MotionTrajectory when unavailable — the fusion
/// engine does not care which source supplied observerPosition.
@Observable
@MainActor
final class ARFieldMapper: NSObject, ARSessionDelegate {

    struct FieldSample: Identifiable {
        let id = UUID()
        var position: SIMD3<Float>
        var rssi: Int
        var targetID: String
        var at: Date
    }

    let session = ARSession()
    private(set) var isTracking = false
    private(set) var samples: [String: [FieldSample]] = [:]
    private(set) var pose: SIMD3<Double> = .zero

    static var isSupported: Bool { ARWorldTrackingConfiguration.isSupported }

    override init() {
        super.init()
        session.delegate = self
    }

    func start(withMesh: Bool = true) {
        guard Self.isSupported else { return }
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravityAndHeading      // aligns +Z to true north: lets AR and
                                                        // dead-reckoning frames be interchanged
        config.planeDetection = [.horizontal, .vertical]
        if withMesh, ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh          // LiDAR: gives wall geometry, which the
                                                        // particle filter can use as an occlusion prior
        }
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    func stop() { session.pause(); isTracking = false }

    func record(targetID: String, rssi: Int) {
        guard let frame = session.currentFrame else { return }
        let t = frame.camera.transform.columns.3
        samples[targetID, default: []].append(
            FieldSample(position: SIMD3(t.x, t.y, t.z), rssi: rssi, targetID: targetID, at: .now))
    }

    /// Gradient of the RF field at the current position — the "warmer/colder" vector.
    /// Least-squares plane fit through the k nearest samples; the in-plane gradient points uphill.
    func gradient(for targetID: String, k: Int = 24) -> SIMD3<Float>? {
        guard let all = samples[targetID], all.count >= k,
              let frame = session.currentFrame else { return nil }
        let here = SIMD3(frame.camera.transform.columns.3.x,
                         frame.camera.transform.columns.3.y,
                         frame.camera.transform.columns.3.z)
        let nearest = all.sorted { simd_distance($0.position, here) < simd_distance($1.position, here) }
                         .prefix(k)
        var ata = simd_float3x3(0); var atb = SIMD3<Float>.zero
        for s in nearest {
            let d = s.position - here
            ata += simd_float3x3(SIMD3(d.x*d.x, d.x*d.y, d.x*d.z),
                                 SIMD3(d.y*d.x, d.y*d.y, d.y*d.z),
                                 SIMD3(d.z*d.x, d.z*d.y, d.z*d.z))
            atb += d * Float(s.rssi)
        }
        guard abs(ata.determinant) > 1e-6 else { return nil }
        return simd_normalize(ata.inverse * atb)
    }

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        Task { @MainActor in
            let t = frame.camera.transform.columns.3
            self.pose = SIMD3(Double(t.x), Double(t.y), Double(t.z))
            self.isTracking = {
                if case .normal = frame.camera.trackingState { return true } else { return false }
            }()
        }
    }
}
