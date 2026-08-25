import SwiftUI
import WatchKit

/// Watch UI. Three screens, no navigation stack deeper than one level — anything more is
/// unusable while walking and looking at a room instead of a wrist.
struct WatchRootView: View {
    @Environment(WatchSensorNode.self) private var node
    @State private var link: DeviceLink
    @State private var haptics = WatchHapticGuidance()
    @State private var guidance: GuidanceCommand?
    @State private var crownDetent: Double = 0

    init(link: DeviceLink) { _link = State(initialValue: link) }

    var body: some View {
        TabView {
            HuntView(guidance: guidance, haptics: haptics, node: node)
                .tag(0)
            SweepView(node: node, guidance: guidance)
                .tag(1)
            StatusView(node: node, link: link)
                .tag(2)
        }
        .tabViewStyle(.verticalPage)
        .onAppear {
            link.onMessage = { message in
                Task { @MainActor in
                    if case let .guidance(command) = message.payload {
                        guidance = command
                        haptics.apply(command, wristHeading: 0)   // supply live wrist heading here
                    }
                }
            }
        }
    }
}

struct HuntView: View {
    let guidance: GuidanceCommand?
    let haptics: WatchHapticGuidance
    let node: WatchSensorNode

    var body: some View {
        VStack(spacing: 6) {
            if let g = guidance {
                // The uncertainty ring IS the interface. It shrinks as the estimate tightens.
                // A single arrow with no radius is a lie the moment the filter is diffuse.
                ZStack {
                    Circle()
                        .stroke(.tertiary, lineWidth: 2)
                        .frame(width: 92, height: 92)
                    Circle()
                        .fill(.tint.opacity(0.18))
                        .frame(width: ringDiameter(g), height: ringDiameter(g))
                    if let bearing = g.bearing {
                        Image(systemName: "location.north.fill")
                            .font(.system(size: 30))
                            .rotationEffect(.radians(bearing))
                    } else {
                        Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 26))
                    }
                }
                Text(g.distance.map { String(format: "%.1f m", $0) } ?? "—")
                    .font(.title3.monospacedDigit().bold())
                Text(g.radius95.map { String(format: "±%.1f m", $0) } ?? "searching")
                    .font(.caption2).foregroundStyle(.secondary)
                if let floor = g.floorDelta, floor != 0 {
                    Label(floor > 0 ? "\(floor) floor up" : "\(-floor) floor down",
                          systemImage: floor > 0 ? "arrow.up" : "arrow.down")
                        .font(.caption2).foregroundStyle(.orange)
                }
            } else {
                ProgressView().controlSize(.large)
                Text("Waiting for phone").font(.caption2).foregroundStyle(.secondary)
            }
        }
        // Double Tap on Series 9+ starts a sweep without touching the screen.
        .handGestureShortcut(.primaryAction)
    }

    private func ringDiameter(_ g: GuidanceCommand) -> Double {
        guard let r = g.radius95 else { return 92 }
        return max(12, min(92, 92 * (r / 15)))
    }
}

struct SweepView: View {
    let node: WatchSensorNode
    let guidance: GuidanceCommand?

    var body: some View {
        VStack(spacing: 8) {
            Text("Wrist Sweep").font(.headline)
            Text("Raise your arm and turn slowly through a full circle.")
                .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button {
                if let target = guidance?.targetID { node.beginWristSweep(targetID: target) }
            } label: {
                Label(node.sweeping ? "Sweeping…" : "Start Sweep",
                      systemImage: node.sweeping ? "arrow.trianglehead.clockwise" : "arrow.clockwise")
            }
            .disabled(node.sweeping || guidance?.targetID == nil)
            .buttonStyle(.borderedProminent)
        }
    }
}

struct StatusView: View {
    let node: WatchSensorNode
    let link: DeviceLink

    var body: some View {
        List {
            LabeledContent("Link", value: link.reachability.rawValue)
            LabeledContent("Scanning", value: node.isScanning ? "Yes" : "No")
            LabeledContent("Runtime", value: node.persistence.rawValue)
            if let remaining = node.runtimeRemaining {
                LabeledContent("Remaining", value: "\(Int(remaining / 60)) min")
            }
            Button("Survey Mode") { Task { try? await node.beginSurveyWorkout() } }
            Button("End Session", role: .destructive) { node.endPersistence() }
        }
    }
}
