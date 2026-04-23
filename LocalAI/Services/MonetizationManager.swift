//
//  MonetizationManager.swift
//  LocalAI
//
//  Created by Codex on 28.03.2026.
//

import Foundation
import StoreKit
import SwiftUI

enum PremiumFeature: String, CaseIterable, Identifiable {
    case allModels
    case advancedPersonality
    case unlimitedDocuments
    case voiceMode
    case imageInput
    case savedPrompts
    case conversationExport
    case chatFolders

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allModels:
            return String(localized: "All Models")
        case .advancedPersonality:
            return String(localized: "Advanced Personality")
        case .unlimitedDocuments:
            return String(localized: "Unlimited Document Chat")
        case .voiceMode:
            return String(localized: "Conversation Mode")
        case .imageInput:
            return String(localized: "Image Input")
        case .savedPrompts:
            return String(localized: "Prompt Library")
        case .conversationExport:
            return String(localized: "Conversation Export")
        case .chatFolders:
            return String(localized: "Chat Folders")
        }
    }

    var subtitle: String {
        switch self {
        case .allModels:
            return String(localized: "Unlock the full local model catalog, including higher-quality and specialty models.")
        case .advancedPersonality:
            return String(localized: "Use custom system prompts, response tuning, and deeper control over how the assistant behaves.")
        case .unlimitedDocuments:
            return String(localized: "Attach more than one document per chat and build richer local research workflows.")
        case .voiceMode:
            return String(localized: "Keep the conversation going hands-free with automatic listen and spoken replies.")
        case .imageInput:
            return String(localized: "Attach photos and ask questions about what you see — powered by on-device vision.")
        case .savedPrompts:
            return String(localized: "Save up to 20 named system prompts and switch AI personas instantly.")
        case .conversationExport:
            return String(localized: "Export any chat as Markdown or plain text and share it anywhere.")
        case .chatFolders:
            return String(localized: "Organize conversations into named folders to keep your chats tidy.")
        }
    }

    var iconName: String {
        switch self {
        case .allModels:
            return "square.stack.3d.up.fill"
        case .advancedPersonality:
            return "slider.horizontal.3"
        case .unlimitedDocuments:
            return "doc.text.fill"
        case .voiceMode:
            return "waveform"
        case .imageInput:
            return "photo.fill"
        case .savedPrompts:
            return "books.vertical.fill"
        case .conversationExport:
            return "square.and.arrow.up.fill"
        case .chatFolders:
            return "folder.fill"
        }
    }
}

@MainActor
@Observable
final class MonetizationManager {
//    static let proEnabledByDefault = true
    static let freeInstallMessageLimit = 5

    private enum StorageKey {
        static let freeInstallMessageCount = "monetization.freeInstallMessageCount"
        static let didWarnAtThreeLeftOnInstall = "monetization.didWarnAtThreeLeftOnInstall"
        static let cachedPurchasedProductIDs = "monetization.cachedPurchasedProductIDs"
    }

    static let productIDs = [
        "ownai.pro.monthly.v2",
        "ownai.pro.yearly.v2",
        "ownai.pro.lifetime"
    ]

    static let freeModelIDs: Set<String> = [
        ModelInfo.appleFoundation.id,
        ModelInfo.gemma3_270m_qat_4bit.id,
        ModelInfo.gemma2_2b_4bit.id
    ]

    var products: [Product] = []
    var purchasedProductIDs: Set<String> = []
    var isLoadingProducts = false
    var isProcessingPurchase = false
    var purchaseErrorMessage: String?
    var freeInstallMessageCount = 0
    var didWarnAtThreeLeftOnInstall = false

    @ObservationIgnored
    @AppStorage(StorageKey.cachedPurchasedProductIDs)
    private var storedPurchasedProductIDs = ""

    @ObservationIgnored
    private var updatesTask: Task<Void, Never>?

    @ObservationIgnored
    private let defaults = UserDefaults.standard



    var hasPro: Bool {
//        Self.proEnabledByDefault || !purchasedProductIDs.isEmpty
        return !purchasedProductIDs.isEmpty

    }

    init() {
        freeInstallMessageCount = defaults.integer(forKey: StorageKey.freeInstallMessageCount)
        didWarnAtThreeLeftOnInstall = defaults.bool(forKey: StorageKey.didWarnAtThreeLeftOnInstall)
        purchasedProductIDs = loadCachedPurchasedProductIDs()
        updatesTask = observeTransactionUpdates()
        Task {
            await refreshProducts()
            await refreshEntitlements()
        }
    }

    deinit {
        updatesTask?.cancel()
    }

    func refreshProducts() async {
        isLoadingProducts = true
        defer { isLoadingProducts = false }

        do {
            let fetchedProducts = try await Product.products(for: Self.productIDs)
            products = fetchedProducts.sorted(by: productSortOrder)
            purchaseErrorMessage = nil
        } catch {
            purchaseErrorMessage = String(localized: "Could not load upgrade options right now.")
        }
    }

    func refreshEntitlements() async {
        var nextPurchasedIDs: Set<String> = []
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            guard isActiveEntitlement(transaction) else { continue }
            nextPurchasedIDs.insert(transaction.productID)
        }
        purchasedProductIDs = nextPurchasedIDs
        cachePurchasedProductIDs(nextPurchasedIDs)
    }

    func purchase(_ product: Product) async -> Bool {
        isProcessingPurchase = true
        defer { isProcessingPurchase = false }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                guard case .verified(let transaction) = verification else {
                    purchaseErrorMessage = String(localized: "Purchase verification failed.")
                    return false
                }
                await transaction.finish()
                await refreshEntitlements()
                purchaseErrorMessage = nil
                return true
            case .userCancelled, .pending:
                return false
            @unknown default:
                purchaseErrorMessage = String(localized: "Purchase could not be completed.")
                return false
            }
        } catch {
            purchaseErrorMessage = error.localizedDescription
            return false
        }
    }

    func restorePurchases() async {
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            purchaseErrorMessage = nil
        } catch {
            purchaseErrorMessage = String(localized: "Could not restore purchases right now.")
        }
    }

    func isPremiumModel(_ model: ModelInfo) -> Bool {
        !Self.freeModelIDs.contains(model.id)
    }

    func canUse(_ feature: PremiumFeature) -> Bool {
        switch feature {
        case .allModels, .advancedPersonality, .unlimitedDocuments, .voiceMode, .imageInput,
             .savedPrompts, .conversationExport, .chatFolders:
            return hasPro
        }
    }

    var freeMessagesUsedToday: Int {
        freeInstallMessageCount
    }

    var freeMessagesRemainingToday: Int {
        max(0, Self.freeInstallMessageLimit - freeMessagesUsedToday)
    }

    var hasReachedFreeDailyMessageLimit: Bool {
        !hasPro && freeMessagesUsedToday >= Self.freeInstallMessageLimit
    }

    var shouldShowThreeMessagesLeftWarning: Bool {
        !hasPro && freeMessagesRemainingToday == 3 && !didWarnAtThreeLeftOnInstall
    }

    func registerFreeMessageIfNeeded() {
        guard !hasPro else { return }
        guard freeInstallMessageCount < Self.freeInstallMessageLimit else { return }
        freeInstallMessageCount += 1
        defaults.set(freeInstallMessageCount, forKey: StorageKey.freeInstallMessageCount)
    }

    func markThreeMessagesLeftWarningShown() {
        didWarnAtThreeLeftOnInstall = true
        defaults.set(true, forKey: StorageKey.didWarnAtThreeLeftOnInstall)
    }

    private func observeTransactionUpdates() -> Task<Void, Never> {
        Task {
            for await result in Transaction.updates {
                guard case .verified(let transaction) = result else { continue }
                await transaction.finish()
                await refreshEntitlements()
            }
        }
    }

    private func isActiveEntitlement(_ transaction: StoreKit.Transaction) -> Bool {
        if transaction.revocationDate != nil {
            return false
        }

        if let expirationDate = transaction.expirationDate, expirationDate <= Date.now {
            return false
        }

        if transaction.isUpgraded {
            return false
        }

        return true
    }

    private func loadCachedPurchasedProductIDs() -> Set<String> {
        guard let data = storedPurchasedProductIDs.data(using: .utf8) else {
            return []
        }

        guard let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }

        return Set(decoded)
    }

    private func cachePurchasedProductIDs(_ productIDs: Set<String>) {
        let encodedIDs = Array(productIDs).sorted()
        guard let data = try? JSONEncoder().encode(encodedIDs),
              let json = String(data: data, encoding: .utf8) else {
            return
        }

        storedPurchasedProductIDs = json
    }

    private func productSortOrder(lhs: Product, rhs: Product) -> Bool {
        rank(for: lhs) < rank(for: rhs)
    }

    private func rank(for product: Product) -> Int {
        switch product.id {
        case "ownai.pro.yearly.v2", "ownai.pro.yearly1":
            return 0
        case "ownai.pro.monthly.v2", "ownai.pro.monthly1":
            return 1
        case "ownai.pro.lifetime":
            return 2
        default:
            return 99
        }
    }
}
