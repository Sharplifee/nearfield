import SwiftUI

/// Watch entry point. The Watch is a sensor node, not a mirror of the phone —
/// it owns its own radio, its own barometer and its own link back to the phone.
@main
struct NearfieldWatchApp: App {
    @State private var link = DeviceLink(role: .watch)
    @State private var node: WatchSensorNode

    init() {
        let link = DeviceLink(role: .watch)
        _link = State(initialValue: link)
        _node = State(initialValue: WatchSensorNode(link: link))
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView(link: link)
                .environment(node)
                .task {
                    node.startMotion()
                    node.startScanning()
                }
        }
    }
}
