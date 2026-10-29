import Foundation
import StoreKit
import Observation

/// The one purchase this app has.
///
/// One book at a time is free, with no limit on time, pages or features: the
/// whole app works on that book forever. The purchase removes the
/// one-at-a-time limit so a shelf can hold several books. It is a single
/// non-consumable, not a subscription, because the app costs nothing to run.
/// There is no server, so there is nothing to rent.
@Observable
@MainActor
final class Store {
    static let shared = Store()

    static let fullShelfID = "com.lowshelf.engrossed.fullshelf"

    private(set) var product: Product?
    private(set) var isUnlocked: Bool
    private(set) var isPurchasing = false
    private(set) var isRestoring = false

    /// Shown to the reader when something goes wrong. Never blocks reading.
    var purchaseError: String?

    private var updatesTask: Task<Void, Never>?

    private let defaults = UserDefaults.standard
    private static let unlockKey = "store.fullShelfUnlocked"

    /// Payment can be forbidden outright by parental controls or a managed
    /// device, in which case offering a buy button is just a dead end.
    var canMakePayments: Bool { AppStore.canMakePayments }

    private init() {
        // Read straight from the cache so the entitlement is right on the very
        // first frame, before any async work has had a chance to run.
        isUnlocked = defaults.bool(forKey: Store.unlockKey)

        // Started at launch and never cancelled. Purchases can arrive without
        // the reader touching the paywall: approved after an Ask to Buy
        // request, shared by a family member, or made on another device.
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                guard case .verified(let transaction) = update else { continue }
                await transaction.finish()
                await self?.refreshEntitlement()
            }
        }

        // Only the local half at launch. Reading a book must not touch the
        // network, and `Product.products(for:)` does.
        Task { await refreshEntitlement() }
    }

    // MARK: - Loading

    /// Called when the unlock sheet opens. This is the only place the app
    /// reaches out to the App Store without the reader asking it to.
    func refresh() async {
        await refreshEntitlement()
        await loadProduct()
    }

    /// A failure here is not an error the reader needs to see. The store being
    /// unreachable on a train must never interrupt reading the free book; it
    /// only means the paywall cannot show a price yet.
    private func loadProduct() async {
        guard product == nil else { return }
        product = try? await Product.products(for: [Store.fullShelfID]).first
    }

    /// Raises the entitlement on evidence, and lowers it only on evidence.
    ///
    /// An empty `currentEntitlements` does not mean "not bought". It also means
    /// "this device has nothing cached yet", which is what a fresh install on a
    /// plane looks like. Treating that as "not bought" would take the shelf away
    /// from someone who paid for it, at the exact moment they cannot do
    /// anything about it. So emptiness is never grounds for locking.
    private func refreshEntitlement() async {
        var owned = false
        var revoked = false

        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  transaction.productID == Store.fullShelfID else { continue }
            if transaction.revocationDate == nil { owned = true } else { revoked = true }
        }

        if owned {
            setUnlocked(true)
        } else if revoked {
            // A refund is real evidence, so this one does lock.
            setUnlocked(false)
        }
    }

    /// Restore can only ever give the shelf back, never take it away.
    ///
    /// It is tempting to treat a successful sync as authoritative and lower the
    /// entitlement when it comes back empty. That would mean someone signed into
    /// the wrong Apple Account, or restoring on a device where the purchase
    /// lives under a family member's account, taps a button labelled "Restore"
    /// and loses the shelf they paid for. Only a revocation ever locks.

    private func setUnlocked(_ value: Bool) {
        isUnlocked = value
        defaults.set(value, forKey: Store.unlockKey)
    }

    // MARK: - Buying

    func purchase() async {
        guard canMakePayments else {
            purchaseError = "Purchases are turned off on this device, probably by Screen Time or a device policy."
            return
        }
        guard let product, !isPurchasing else { return }
        isPurchasing = true
        defer { isPurchasing = false }

        do {
            switch try await product.purchase() {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    await transaction.finish()
                    setUnlocked(true)
                case .unverified:
                    // Signature check failed. Rare, and not something to
                    // silently trust.
                    purchaseError = "That purchase couldn’t be verified. Nothing has been charged."
                }
            case .userCancelled:
                break
            case .pending:
                // Ask to Buy, or a payment awaiting approval. The listener
                // above will pick it up whenever it clears.
                purchaseError = "Waiting for approval. The full shelf is yours as soon as it comes through."
            @unknown default:
                break
            }
        } catch {
            purchaseError = error.localizedDescription
        }
    }

    /// Apple requires a way to restore a non-consumable on a new device.
    func restore() async {
        guard !isRestoring else { return }
        isRestoring = true
        defer { isRestoring = false }

        do {
            try await AppStore.sync()
            await refreshEntitlement()
            if !isUnlocked {
                purchaseError = "No previous purchase found on this Apple Account."
            }
        } catch {
            purchaseError = error.localizedDescription
        }
    }

    /// Localised, and never hardcoded: the price differs by storefront.
    var displayPrice: String? { product?.displayPrice }
}
