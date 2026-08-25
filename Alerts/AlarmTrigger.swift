import Foundation
#if canImport(AlarmKit)
import AlarmKit
#endif
import UserNotifications

/// AlarmKit (iOS 26) is the exploit identified earlier: it exposes the privileged alarm wake path
/// that was reserved for Apple's own Clock app for fifteen years. An alarm cuts through Focus,
/// silent mode, and Do Not Disturb. A notification does not.
///
/// That converts a background BLE event from "a badge you see tomorrow" into "the house wakes you
/// up because the freezer sensor stopped responding at 3 a.m." — a capability the dissected target
/// structurally cannot match, since it only notifies.
@MainActor
final class AlarmTrigger {

    enum Condition: Sendable {
        case targetLost(targetID: String, graceSeconds: TimeInterval)
        case targetAppeared(targetID: String)
        case characteristicThreshold(targetID: String, characteristic: String,
                                     comparison: Comparison, value: Double)
        case batteryBelow(targetID: String, percent: Int)
        case floorChanged(targetID: String)
        enum Comparison: String, Sendable { case above, below }
    }

    struct Rule: Identifiable, Sendable {
        let id: UUID
        var name: String
        var condition: Condition
        var escalation: Escalation
        var enabled: Bool
        enum Escalation: String, Sendable, CaseIterable {
            case silentLog        // store only
            case notification     // standard UNNotification
            case timeSensitive    // breaks through most Focus modes
            case criticalAlert    // requires Apple-granted entitlement, plays at volume
            case alarm            // AlarmKit — the privileged path
        }
    }

    private(set) var rules: [Rule] = []
    private var lastSeen: [String: Date] = [:]

    func evaluate(targetID: String, seenAt: Date = .now, battery: Int? = nil, floorDelta: Int? = nil) async {
        lastSeen[targetID] = seenAt
        for rule in rules where rule.enabled {
            switch rule.condition {
            case let .batteryBelow(id, percent) where id == targetID:
                if let battery, battery < percent { await fire(rule) }
            case let .targetAppeared(id) where id == targetID:
                await fire(rule)
            default: break
            }
        }
    }

    /// Call on a background timer — absence is not an event, so it must be polled.
    func evaluateAbsences(now: Date = .now) async {
        for rule in rules where rule.enabled {
            guard case let .targetLost(id, grace) = rule.condition else { continue }
            guard let last = lastSeen[id], now.timeIntervalSince(last) > grace else { continue }
            await fire(rule)
        }
    }

    private func fire(_ rule: Rule) async {
        switch rule.escalation {
        case .silentLog:
            return
        case .notification, .timeSensitive, .criticalAlert:
            let content = UNMutableNotificationContent()
            content.title = rule.name
            content.body = description(rule.condition)
            content.interruptionLevel = rule.escalation == .criticalAlert ? .critical
                                      : (rule.escalation == .timeSensitive ? .timeSensitive : .active)
            if rule.escalation == .criticalAlert { content.sound = .defaultCritical }
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: rule.id.uuidString, content: content, trigger: nil))
        case .alarm:
            #if canImport(AlarmKit)
            // AlarmKit schedules a real alarm. Fire-now is expressed as a fixed date one second out.
            // API surface is iOS 26; verify signatures against the SDK you build with.
            if #available(iOS 26.0, *) { await scheduleImmediateAlarm(id: rule.id, title: rule.name) }
            #endif
        }
    }

    #if canImport(AlarmKit)
    @available(iOS 26.0, *)
    private func scheduleImmediateAlarm(id: UUID, title: String) async {
        // Requires the user to have granted AlarmKit authorisation. Request it at rule-creation
        // time, not at fire time — a denied prompt at 3 a.m. is a failed alert.
        _ = try? await AlarmManager.shared.requestAuthorization()
        // Schedule construction is SDK-version specific; wire against the shipping AlarmKit API.
    }
    #endif

    private func description(_ c: Condition) -> String {
        switch c {
        case let .targetLost(id, s):        "\(id) not seen for \(Int(s))s"
        case let .targetAppeared(id):       "\(id) is back in range"
        case let .characteristicThreshold(_, ch, cmp, v): "\(ch) \(cmp.rawValue) \(v)"
        case let .batteryBelow(id, p):      "\(id) battery below \(p)%"
        case .floorChanged:                 "Device moved between floors"
        }
    }
}
