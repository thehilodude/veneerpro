import StoreKit
import SwiftUI

/// The Support Veneer Pro window: optional tips that unlock nothing.
struct TipJarView: View {
    static let windowID = "tipjar"
    @State private var jar = TipJar.shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "cup.and.heat.waves.fill")
                .appFont(34)
                .foregroundStyle(.orange)
            Text("Support Veneer Pro").appFont(17, weight: .semibold)
            Text("Veneer Pro is free and made by one person. If it helps your work, a tip keeps it going. Tips are optional and don't unlock anything; every feature stays free.")
                .appFont(12).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            content
        }
        .padding(24)
        .frame(width: 380)
        .task { await jar.load() }
        .onDisappear { jar.reset() }
    }

    @ViewBuilder private var content: some View {
        if TipJar.usesInAppPurchase {
            switch jar.state {
            case .thanks:
                Label("Thank you! Your support means a lot.", systemImage: "heart.fill")
                    .appFont(13, weight: .medium).foregroundStyle(.pink)
                    .padding(.top, 4)
            case .loading:
                ProgressView().padding(.top, 4)
            case .unavailable:
                Text("Tips aren't available right now. Please try again later.")
                    .appFont(11).foregroundStyle(.secondary)
            case .idle, .purchasing:
                HStack(spacing: 10) {
                    ForEach(Array(jar.products.enumerated()), id: \.element.id) { index, product in
                        Button { Task { await jar.buy(product) } } label: {
                            VStack(spacing: 4) {
                                Text(["☕️", "☕️☕️", "☕️☕️☕️"][min(index, 2)]).appFont(16)
                                Text(product.displayName).appFont(11, weight: .medium).lineLimit(1)
                                Text(product.displayPrice).appFont(12, weight: .semibold, monospacedDigits: true)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .disabled(jar.state == .purchasing)
            }
        } else if let url = TipJar.coffeeURL {
            Button { openURL(url) } label: {
                Label("Buy Me a Coffee", systemImage: "cup.and.saucer.fill")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .controlSize(.large)
        }
    }
}
