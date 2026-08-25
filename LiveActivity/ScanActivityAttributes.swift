import ActivityKit
import Foundation

/// Background scanning is only honest if the user can see it running.
/// Divergence from the target: their Live Activity is a status mirror.
/// Ours carries PINNED METRIC VALUES, which is the LiveActivityLab thesis —
/// the Island is the product surface, not a progress indicator.
struct ScanActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var visibleDevices: Int
        var totalDevices: Int
        var startedAt: Date
        var lastEventAt: Date
        var filterLabel: String
        /// Up to three characteristic values pinned to the Island by the user.
        var pinned: [PinnedMetric]
    }
    var sessionID: UUID
}

struct PinnedMetric: Codable, Hashable, Identifiable {
    var id: String            // peripheralUUID + characteristicUUID
    var label: String
    var value: String
    var symbol: String        // SF Symbol
    var isStale: Bool
}
