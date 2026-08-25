import Foundation
import NearbyInteraction
import CoreBluetooth
import simd

/// UWB ranging. READ THIS BEFORE DESIGNING AROUND IT.
///
/// NearbyInteraction cannot range an arbitrary BLE device. Two and only two paths exist:
///
///  A) PEER — another iPhone/Watch running THIS app. You exchange NIDiscoveryToken over a
///     side channel (we use a custom GATT characteristic + MultipeerConnectivity fallback).
///     Yields distance AND direction. This is how you turn a second device into a second antenna.
///
///  B) ACCESSORY — third-party hardware implementing Apple's UWB Accessory Protocol
///     (Qorvo DW3000, NXP SR150 class). The accessory publishes a GATT service; you read its
///     configuration blob, build NINearbyAccessoryConfiguration, and hand the accessory back
///     the shareable configuration data over the same GATT link.
///
/// Path B is the one that matters for the Home Monitoring System: a $12 DW3000 module per room
/// gives 10 cm anchors, which collapses the whole localisation problem.
@Observable
@MainActor
final class UWBRanging: NSObject {

    struct Capability: Sendable {
        var preciseDistance: Bool
        var direction: Bool
        var cameraAssistance: Bool
        var extendedDistance: Bool
    }

    private(set) var capability: Capability = .init(preciseDistance: false, direction: false,
                                                    cameraAssistance: false, extendedDistance: false)
    private(set) var isRunning = false
    private var sessions: [String: NISession] = [:]     // targetID -> session
    var onObservation: (@MainActor (RFObservation) -> Void)?
    var observerPose: () -> SIMD3<Double> = { .zero }

    override init() {
        super.init()
        let caps = NISession.deviceCapabilities
        capability = Capability(
            preciseDistance: caps.supportsPreciseDistanceMeasurement,
            direction: caps.supportsDirectionMeasurement,
            cameraAssistance: caps.supportsCameraAssistance,
            extendedDistance: caps.supportsExtendedDistanceMeasurement
        )
    }

    /// PATH A — peer device running this app.
    /// Publish `localToken` over your own GATT characteristic; when the peer's token arrives, call this.
    func startPeer(targetID: String, peerToken: NIDiscoveryToken, cameraAssisted: Bool = true) {
        guard capability.preciseDistance else { return }
        let session = NISession()
        session.delegate = self
        let config = NINearbyPeerConfiguration(peerToken: peerToken)
        if capability.cameraAssistance, cameraAssisted { config.isCameraAssistanceEnabled = true }
        sessions[targetID] = session
        session.run(config)
        isRunning = true
    }

    var localToken: NIDiscoveryToken? { sessions.values.first?.discoveryToken }

    /// PATH B — UWB accessory.
    /// `configurationData` comes from the accessory's own GATT characteristic. The accessory
    /// protocol is a handshake: accessory sends config -> we build session -> we send back
    /// `shareableConfigurationData` from didGenerateShareableConfigurationData -> accessory starts.
    func startAccessory(targetID: String, configurationData: Data) throws {
        let config = try NINearbyAccessoryConfiguration(data: configurationData)
        if capability.cameraAssistance { config.isCameraAssistanceEnabled = true }
        let session = NISession()
        session.delegate = self
        sessions[targetID] = session
        session.run(config)
        isRunning = true
    }

    /// Called back with the blob you must write to the accessory to complete the handshake.
    var onShareableConfiguration: (@MainActor (String, Data) -> Void)?

    func stop(_ targetID: String) {
        sessions[targetID]?.invalidate()
        sessions[targetID] = nil
        isRunning = !sessions.isEmpty
    }

    private func targetID(forKey key: ObjectIdentifier) -> String? {
        sessions.first { ObjectIdentifier($0.value) == key }?.key
    }
}

extension UWBRanging: NISessionDelegate {

    nonisolated func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        // Extract Sendable scalars before crossing to the main actor.
        let readings: [(Float?, SIMD3<Float>?)] = nearbyObjects.map { ($0.distance, $0.direction) }
        let key = ObjectIdentifier(session)
        Task { @MainActor in
            guard let target = self.targetID(forKey: key) else { return }
            let pose = self.observerPose()
            for (distanceValue, directionValue) in readings {
                if let distance = distanceValue {
                    self.onObservation?(RFObservation(
                        targetID: target, modality: .uwbDistance, at: .now,
                        observerPosition: pose, observerHeading: nil,
                        range: Double(distance),
                        rangeSigma: RFObservation.defaultSigma(.uwbDistance)))
                }
                if let direction = directionValue {
                    self.onObservation?(RFObservation(
                        targetID: target, modality: .uwbDirection, at: .now,
                        observerPosition: pose, observerHeading: nil,
                        direction: direction, directionSigma: 0.175))
                }
            }
        }
    }

    nonisolated func session(_ session: NISession,
                             didGenerateShareableConfigurationData data: Data,
                             for object: NINearbyObject) {
        let key = ObjectIdentifier(session)
        Task { @MainActor in
            guard let target = self.targetID(forKey: key) else { return }
            self.onShareableConfiguration?(target, data)
        }
    }

    nonisolated func session(_ session: NISession,
                             didRemove nearbyObjects: [NINearbyObject],
                             reason: NINearbyObject.RemovalReason) {
        // .timeout is normal when the peer goes out of UWB range (~9 m indoors, 15 m extended).
        // Do NOT tear down the BLE link on timeout — BLE reaches much further and is the fallback.
    }

    nonisolated func sessionWasSuspended(_ session: NISession) {}
    nonisolated func sessionSuspensionEnded(_ session: NISession) {
        if let config = session.configuration { session.run(config) }
    }
    nonisolated func session(_ session: NISession, didInvalidateWith error: Error) {}
}
