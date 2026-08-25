import Foundation
import StoreKit
import Observation

/// BUILD ORDER NOTE — this ships at step 3, before any gated feature exists.
/// The target shipped it last and then spent four releases (1.7.5 through 1.7.8) fixing
/// restoration race conditions, silent failures, and a crash on the one screen only
/// paying customers ever see.
@Observable
@MainActor
final class Entitlements {

    static let proProductID = "com.connor.nearfield.pro"

    private(set) var isPro = false
    private(set) var product: Product?
    private(set) var isRestoring = false
    private(set) var lastResult: String?

    private var updatesTask: Task<Void, Never>?

    /// ORDER IS LOAD-BEARING. Start the updates listener BEFORE sweeping current entitlements.
    /// Reversing these two lines is the exact race the target shipped in 1.7.6 and patched in 1.7.7:
    /// a transaction arriving between the sweep and the listener attaching is dropped on the floor.
    func bootstrap() async {
        updatesTask = Task.detached { [weak self] in
            for await update in Transaction.updates {
                await self?.apply(update)
            }
        }
        await refreshEntitlements()
        product = try? await Product.products(for: [Self.proProductID]).first
    }

    func refreshEntitlements() async {
        var owned = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let t) = result else { continue }
            if t.productID == Self.proProductID, t.revocationDate == nil { owned = true }
        }
        isPro = owned
        mirrorToAppGroup()
    }

    private func apply(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let t) = result else { return }
        if t.productID == Self.proProductID {
            isPro = (t.revocationDate == nil)
            mirrorToAppGroup()
        }
        await t.finish()
    }

    func purchase() async {
        guard let product else { lastResult = "Product unavailable. Check your connection."; return }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                await apply(verification)
                lastResult = isPro ? "Pro unlocked." : "Purchase could not be verified."
            case .userCancelled: lastResult = nil
            case .pending:       lastResult = "Waiting for approval."
            @unknown default:    lastResult = "Unknown purchase result."
            }
        } catch {
            // NEVER swallow this. The target's 1.7.8 note "purchases failing silently" is this catch block.
            lastResult = "Purchase failed: \(error.localizedDescription)"
        }
    }

    /// Always show progress and always show a terminal result — success or failure.
    func restore() async {
        isRestoring = true
        defer { isRestoring = false }
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            lastResult = isPro ? "Pro restored." : "No previous purchase found on this Apple Account."
        } catch {
            lastResult = "Restore failed: \(error.localizedDescription)"
        }
    }

    /// The Live Activity and App Clip are SEPARATE PROCESSES and cannot read StoreKit state
    /// synchronously at launch. Mirror the flag into the shared container. Omitting this is the
    /// most likely cause of the target's "I purchased Pro but it won't unlock" reports.
    private func mirrorToAppGroup() {
        UserDefaults(suiteName: "group.com.connor.nearfield")?.set(isPro, forKey: "isPro")
    }
}
