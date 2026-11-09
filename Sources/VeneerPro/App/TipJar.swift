import Foundation
import Observation
import StoreKit

/// Optional tips (Help ▸ Support Veneer Pro… on Mac, the File menu on iPad). On iPad and in the Mac App
/// Store edition they're consumable in-app purchases; they unlock nothing. In-app purchases only work
/// in apps installed from the App Store, so the Mac GitHub edition offers a Buy Me a Coffee link instead
/// (when one is set).
@MainActor @Observable
final class TipJar {
    static let shared = TipJar()

    /// Consumable products to create in App Store Connect (Monetization ▸ In-App Purchases).
    static let productIDs = [
        "com.thehilodude.veneerpro.tip.small",
        "com.thehilodude.veneerpro.tip.medium",
        "com.thehilodude.veneerpro.tip.large",
    ]

    /// The Mac GitHub edition's tip link. Empty hides it. Never shown on iPad or in the App Store
    /// edition: the App Store doesn't allow outside links for tips.
    static let coffeeURL: URL? = URL(string: "https://buymeacoffee.com/kevinjyp")

    /// iPad apps can only come from the App Store (or a developer's own install), so they never link out.
    static var usesInAppPurchase: Bool {
        #if os(iOS)
        true
        #else
        Distribution.isAppStore
        #endif
    }

    /// Whether there's any way to tip in this edition.
    static var isAvailable: Bool { usesInAppPurchase || coffeeURL != nil }

    enum State: Equatable { case idle, loading, unavailable, purchasing, thanks }

    private(set) var products: [Product] = []
    private(set) var state: State = .idle
    @ObservationIgnored private var updates: Task<Void, Never>?

    private init() {
        guard Self.usesInAppPurchase else { return }
        // Finish any tip that completed while the app wasn't watching (e.g. approved later via Ask to Buy).
        updates = Task {
            for await result in Transaction.updates {
                if case .verified(let transaction) = result { await transaction.finish() }
            }
        }
    }

    func load() async {
        guard Self.usesInAppPurchase, products.isEmpty, state != .loading else { return }
        state = .loading
        do {
            products = try await Product.products(for: Self.productIDs).sorted { $0.price < $1.price }
            state = products.isEmpty ? .unavailable : .idle
        } catch {
            state = .unavailable
        }
    }

    func buy(_ product: Product) async {
        state = .purchasing
        do {
            switch try await product.purchase() {
            case .success(.verified(let transaction)):
                await transaction.finish()
                state = .thanks
            case .success(.unverified(let transaction, _)):
                await transaction.finish()
                state = .idle
            case .pending, .userCancelled:
                state = .idle
            @unknown default:
                state = .idle
            }
        } catch {
            state = .idle
        }
    }

    func reset() { if state == .thanks { state = .idle } }
}
