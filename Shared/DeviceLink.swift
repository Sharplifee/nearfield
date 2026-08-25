import Foundation
import WatchConnectivity

/// WatchConnectivity transport with tiered delivery. Both nodes use this class.
///
/// TRANSPORT SELECTION MATTERS AND IS NOT OPTIONAL:
///   sendMessage            — immediate, requires BOTH apps foreground/reachable. Drops otherwise.
///   transferUserInfo       — queued, FIFO, guaranteed, survives termination. Latency seconds to minutes.
///   updateApplicationContext — latest-value-wins, overwrites. Perfect for status, wrong for observations.
///   transferFile           — bulk. Used for sweep archives and log export.
///
/// Observations go by sendMessage while hunting (latency matters) and fall back to
/// transferUserInfo batches when the link drops (completeness matters). Status goes by
/// applicationContext always — you only care about the current battery level, never the history.
@Observable
final class DeviceLink: NSObject, WCSessionDelegate, @unchecked Sendable {

    enum Reachability: String { case unpaired, notInstalled, inactive, background, reachable }

    private(set) var reachability: Reachability = .inactive
    private(set) var peerStatus: NodeStatus?
    private(set) var lastError: String?

    let role: NodeRole
    let clock = ClockSync()

    var onMessage: (@Sendable (NodeMessage) -> Void)?

    /// Observations pending when the link is unreachable. Flushed as one batch on reconnect —
    /// a hundred separate transferUserInfo calls will hit the queue limit and start dropping.
    private var outbox: [WireObservation] = []
    private let outboxLimit = 400
    private let queue = DispatchQueue(label: "com.connor.nearfield.link")

    init(role: NodeRole) {
        self.role = role
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    // MARK: Send

    func send(_ payload: NodeMessage.Payload, urgent: Bool = false) {
        let message = NodeMessage(sender: role, sentAt: .now,
                                  monotonicNanos: ClockSync.now(), payload: payload)
        guard let data = try? JSONEncoder().encode(message) else { return }
        let session = WCSession.default

        if urgent, session.isReachable {
            session.sendMessageData(data, replyHandler: nil) { [weak self] error in
                self?.lastError = error.localizedDescription
                // Reachable-but-failed: requeue rather than lose it.
                session.transferUserInfo(["payload": data])
            }
        } else {
            session.transferUserInfo(["payload": data])
        }
    }

    /// Observations are buffered and shipped in batches. One message per BLE advertisement
    /// would saturate the link instantly — the Watch can see hundreds of packets per second.
    func enqueue(_ observation: WireObservation) {
        queue.async { [self] in
            outbox.append(observation)
            if outbox.count > outboxLimit { outbox.removeFirst(outbox.count - outboxLimit) }
            if outbox.count >= 25 || WCSession.default.isReachable { flush() }
        }
    }

    func flush() {
        queue.async { [self] in
            guard !outbox.isEmpty else { return }
            let batch = outbox
            outbox.removeAll(keepingCapacity: true)
            send(.observationBatch(batch), urgent: WCSession.default.isReachable)
        }
    }

    /// Latest-value-wins. Never use this for observations — it silently discards.
    func publishStatus(_ status: NodeStatus) {
        let message = NodeMessage(sender: role, sentAt: .now,
                                  monotonicNanos: ClockSync.now(), payload: .nodeStatus(status))
        guard let data = try? JSONEncoder().encode(message) else { return }
        try? WCSession.default.updateApplicationContext(["status": data])
    }

    func pingClock() {
        send(.clockPing(id: UUID()), urgent: true)
    }

    // MARK: Receive

    private func handle(_ data: Data) {
        guard var message = try? JSONDecoder().decode(NodeMessage.self, from: data) else { return }
        // Forward compatibility: never crash on a newer peer, just ignore unknown payloads.
        guard message.version <= NodeMessage.currentVersion + 2 else { return }

        if case let .clockPing(id) = message.payload {
            let received = ClockSync.now()
            send(.clockPong(id: id, receivedAtNanos: received, repliedAtNanos: ClockSync.now()), urgent: true)
            return
        }
        if case let .clockPong(_, t1, t2) = message.payload {
            let t3 = ClockSync.now()
            Task { await clock.record(sentAt: message.monotonicNanos, remoteReceived: t1,
                                       remoteReplied: t2, receivedAt: t3) }
            return
        }
        if case let .nodeStatus(status) = message.payload { peerStatus = status }
        // version already validated above
        onMessage?(message)
    }

    func session(_ s: WCSession, didReceiveMessageData messageData: Data) { handle(messageData) }
    func session(_ s: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        if let data = userInfo["payload"] as? Data { handle(data) }
    }
    func session(_ s: WCSession, didReceiveApplicationContext context: [String: Any]) {
        if let data = context["status"] as? Data { handle(data) }
    }

    func session(_ s: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        updateReachability(s)
        if state == .activated { pingClock() }
    }
    func sessionReachabilityDidChange(_ s: WCSession) {
        updateReachability(s)
        if s.isReachable { flush(); pingClock() }
    }

    private func updateReachability(_ s: WCSession) {
        #if os(iOS)
        if !s.isPaired { reachability = .unpaired; return }
        if !s.isWatchAppInstalled { reachability = .notInstalled; return }
        #endif
        reachability = s.isReachable ? .reachable
                     : (s.activationState == .activated ? .background : .inactive)
    }

    #if os(iOS)
    func sessionDidBecomeInactive(_ s: WCSession) { reachability = .inactive }
    func sessionDidDeactivate(_ s: WCSession) { WCSession.default.activate() }
    #endif
}
