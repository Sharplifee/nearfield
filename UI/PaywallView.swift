import SwiftUI
import StoreKit

/// The highest-leverage screen in the product.
/// The target added "demos of the pro functionality" in 1.3.1 only after a public review
/// said the buyer couldn't tell what he'd get. Build the demo first, not the bullet list.
struct PaywallView: View {
    @Environment(Entitlements.self) private var entitlements
    @Environment(\.dismiss) private var dismiss
    let highlight: ProFeature
    @State private var showing: ProFeature

    init(highlight: ProFeature) {
        self.highlight = highlight
        _showing = State(initialValue: highlight)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Live, looping demonstration against a mock peripheral — not a screenshot.
                    FeatureDemoView(feature: showing)
                        .frame(height: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 20))

                    Picker("Feature", selection: $showing) {
                        ForEach(ProFeature.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    Text(showing.blurb)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    if let product = entitlements.product {
                        Button {
                            Task { await entitlements.purchase(); if entitlements.isPro { dismiss() } }
                        } label: {
                            Text("Unlock Pro — \(product.displayPrice)")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        Text("One-time purchase. Shared with your Family group.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ProgressView().task { await entitlements.bootstrap() }
                    }

                    // Always visible, always shows progress, always shows a terminal result.
                    Button {
                        Task { await entitlements.restore(); if entitlements.isPro { dismiss() } }
                    } label: {
                        if entitlements.isRestoring { ProgressView() } else { Text("Restore Purchase") }
                    }
                    .disabled(entitlements.isRestoring)

                    if let message = entitlements.lastResult {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
            .navigationTitle("Nearfield Pro")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }
}

/// Replace each case with a real animated demo driven by a mock peripheral fixture.
struct FeatureDemoView: View {
    let feature: ProFeature
    var body: some View {
        ZStack { Rectangle().fill(.quaternary); Text("DEMO: \(feature.title)").font(.headline) }
    }
}
