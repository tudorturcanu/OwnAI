//
//  UpgradeView.swift
//  LocalAI
//
//  Created by Codex on 28.03.2026.
//

import StoreKit
import SwiftUI

struct UpgradeView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MonetizationManager.self) private var monetizationManager

    private let privacyPolicyURL = URL(string: "https://sudoswisshub.github.io/MetalMind-AI/privacy.html")!
    private let termsOfUseURL = URL(string: "https://sudoswisshub.github.io/MetalMind-AI/terms.html")!

    let feature: PremiumFeature

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    heroCard
                    featureList
                    productsSection
                    subscriptionDisclosureSection
                    restoreSection
                }
                .padding(20)
            }
            .background(Color(white: 0.97))
            .navigationTitle("Upgrade to Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                    .disabled(monetizationManager.isProcessingPurchase)
                }
            }
        }
        .overlay {
            if monetizationManager.isProcessingPurchase {
                purchaseLoadingOverlay
            }
        }
        .task {
            if monetizationManager.products.isEmpty {
                await monetizationManager.refreshProducts()
            }
            await monetizationManager.refreshEntitlements()
        }
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(
                            LinearGradient(
                                colors: [.orange.opacity(0.16), .pink.opacity(0.14)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 56, height: 56)

                    Image(systemName: feature.iconName)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.orange, .pink],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(LocalizedStringKey(feature.title))
                        .font(.title3.bold())
                        .foregroundStyle(Color(white: 0.1))
                    Text(LocalizedStringKey(feature.subtitle))
                        .font(.subheadline)
                        .foregroundStyle(Color(white: 0.45))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text("Unlock the most capable private workflow in Own AI with more models, richer document chat, deeper control, and hands-free use.")
                .font(.subheadline)
                .foregroundStyle(Color(white: 0.48))
        }
        .padding(18)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.04), radius: 10, y: 4)
    }

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Included in Pro")
                .font(.headline)
                .foregroundStyle(Color(white: 0.2))

            VStack(spacing: 0) {
                upgradeRow(
                    icon: "square.stack.3d.up.fill",
                    title: String(localized: "All local model families"),
                    subtitle: String(localized: "Unlock the full catalog instead of only the starter models.")
                )
                Divider().padding(.leading, 52)
                upgradeRow(
                    icon: "slider.horizontal.3",
                    title: String(localized: "Advanced personality controls"),
                    subtitle: String(localized: "Custom prompts, response size, and tuning controls.")
                )
                Divider().padding(.leading, 52)
                upgradeRow(
                    icon: "doc.text.fill",
                    title: String(localized: "Unlimited docs per chat"),
                    subtitle: String(localized: "Move beyond the free single-document workflow.")
                )
                Divider().padding(.leading, 52)
                upgradeRow(
                    icon: "waveform",
                    title: String(localized: "Hands-free conversation mode"),
                    subtitle: String(localized: "Automatic listen and spoken replies for faster voice use.")
                )
            }
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .shadow(color: .black.opacity(0.04), radius: 8, y: 4)
        }
    }

    @ViewBuilder
    private var productsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Plans")
                .font(.headline)
                .foregroundStyle(Color(white: 0.2))

            if monetizationManager.isLoadingProducts {
                ProgressView("Loading plans…")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(24)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
            } else if monetizationManager.products.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Plans will appear here soon.")
                        .font(.subheadline.weight(.semibold))
                    Text("This build does not have live App Store products available yet.")
                        .font(.caption)
                        .foregroundStyle(Color(white: 0.5))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 18))
            } else {
                VStack(spacing: 12) {
                    ForEach(monetizationManager.products, id: \.id) { product in
                        productCard(product)
                    }
                }
            }

            if let errorMessage = monetizationManager.purchaseErrorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 4)
            }
        }
    }

    private var restoreSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if monetizationManager.hasPro {
                Text("Pro is already unlocked on this device.")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)
            }

            Button("Restore Purchases") {
                Task {
                    await monetizationManager.restorePurchases()
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.blue)
            .disabled(monetizationManager.isProcessingPurchase)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var subscriptionDisclosureSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Subscription Information")
                .font(.headline)
                .foregroundStyle(Color(white: 0.2))

            VStack(alignment: .leading, spacing: 10) {
                Text("Own AI Pro Monthly renews every month. Own AI Pro Yearly renews every year.")
                    .font(.footnote)
                    .foregroundStyle(Color(white: 0.48))
                    .fixedSize(horizontal: false, vertical: true)

                Text("Payment is charged to your Apple Account at confirmation. Auto-renewable subscriptions renew automatically unless canceled at least 24 hours before the end of the current period.")
                    .font(.footnote)
                    .foregroundStyle(Color(white: 0.48))
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 16) {
                    Link("Privacy Policy", destination: privacyPolicyURL)
                    Link("Terms of Use (EULA)", destination: termsOfUseURL)
                }
                .font(.footnote.weight(.semibold))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .shadow(color: .black.opacity(0.04), radius: 8, y: 4)
        }
    }

    private var purchaseLoadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)

                Text("Processing purchase…")
                    .font(.headline)
                    .foregroundStyle(.white)

                Text("Please wait a moment.")
                    .font(.subheadline)
                    .foregroundStyle(Color.white.opacity(0.85))
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .background(Color.black.opacity(0.82))
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .shadow(color: .black.opacity(0.2), radius: 18, y: 10)
        }
        .transition(.opacity)
    }

    private func upgradeRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(.orange)
                .frame(width: 24, height: 24)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey(title))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(white: 0.1))
                Text(LocalizedStringKey(subtitle))
                    .font(.caption)
                    .foregroundStyle(Color(white: 0.48))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func productCard(_ product: Product) -> some View {
        let isRecommended = product.id == "ownai.pro.yearly.v2" || product.id == "ownai.pro.yearly1"

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(product.displayName)
                            .font(.headline)
                            .foregroundStyle(Color(white: 0.1))
                        if isRecommended {
                            Text("BEST VALUE")
                                .font(.caption2.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green)
                                .clipShape(Capsule())
                        }
                    }
                    Text(product.description)
                        .font(.caption)
                        .foregroundStyle(Color(white: 0.48))

                    Text(subscriptionLength(for: product))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color(white: 0.36))
                }

                Spacer()

                Text(product.displayPrice)
                    .font(.title3.bold())
                    .foregroundStyle(Color(white: 0.1))
            }

            Button {
                Task {
                    let purchased = await monetizationManager.purchase(product)
                    if purchased {
                        dismiss()
                    }
                }
            } label: {
                HStack {
                    Spacer()
                    Text("Unlock Pro")
                        .font(.headline.weight(.semibold))
                    Spacer()
                }
                .padding(.vertical, 14)
                .background(
                    LinearGradient(
                        colors: isRecommended ? [.orange, .pink] : [.blue, .blue.opacity(0.86)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .disabled(monetizationManager.isProcessingPurchase)
        }
        .padding(18)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.04), radius: 8, y: 4)
    }

    private func subscriptionLength(for product: Product) -> String {
        switch product.id {
        case "ownai.pro.monthly.v2", "ownai.pro.monthly1":
            return String(localized: "Length: 1 month")
        case "ownai.pro.yearly.v2", "ownai.pro.yearly1":
            return String(localized: "Length: 1 year")
        case "ownai.pro.lifetime":
            return String(localized: "Length: Lifetime access")
        default:
            return String(localized: "Length: See App Store details")
        }
    }
}

#Preview {
    UpgradeView(feature: .allModels)
        .environment(MonetizationManager())
}
