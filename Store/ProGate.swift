import SwiftUI

/// Gate at PRESENTATION, not at execution. The user should always see the shape of the
/// locked capability — the target's own changelog (1.3.1) records adding demos to the
/// purchase screen after a reviewer said he couldn't tell what he'd be buying.
struct ProGate: ViewModifier {
    @Environment(Entitlements.self) private var entitlements
    @State private var showPaywall = false
    let feature: ProFeature

    func body(content: Content) -> some View {
        if entitlements.isPro {
            content
        } else {
            content
                .disabled(true)
                .redacted(reason: .placeholder)
                .overlay(alignment: .center) {
                    Button { showPaywall = true } label: {
                        Label(feature.title, systemImage: "lock.fill")
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(.thinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .sheet(isPresented: $showPaywall) { PaywallView(highlight: feature) }
        }
    }
}

enum ProFeature: String, CaseIterable, Identifiable {
    case write, valueHistory, sessionLog, shortcuts
    var id: String { rawValue }
    var title: String {
        switch self {
        case .write:        "Write values"
        case .valueHistory: "Value history"
        case .sessionLog:   "Session log & export"
        case .shortcuts:    "Shortcuts actions"
        }
    }
    var blurb: String {
        switch self {
        case .write:        "Send string, numeric or hex values back to any writable characteristic."
        case .valueHistory: "Every value change since the session started, timestamped."
        case .sessionLog:   "Full event log with .log export for offline analysis."
        case .shortcuts:    "Scan, interrogate, read and write from the Shortcuts app."
        }
    }
}

extension View {
    func proGated(_ feature: ProFeature) -> some View { modifier(ProGate(feature: feature)) }
}
