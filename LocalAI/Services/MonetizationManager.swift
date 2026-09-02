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
    case unlimitedMessages
    case allModels
    case advancedPersonality
    case unlimitedDocuments
    case voiceMode
    case imageInput
    case savedPrompts
    case conversationExport
    case chatFolders
    case importedModels

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unlimitedMessages:
            return String(localized: "Unlimited Messages")
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
        case .importedModels:
            return String(localized: "Import Your Own Models")
        }
    }

    var subtitle: String {
        switch self {
        case .unlimitedMessages:
            return String(localized: "Keep chatting without the daily free-message limit.")
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
        case .importedModels:
            return String(localized: "Bring your own MLX model from Files and run it on-device alongside the built-in catalog.")
        }
    }

    var iconName: String {
        switch self {
        case .unlimitedMessages:
            return "message.badge.fill"
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
        case .importedModels:
            return "square.and.arrow.down.on.square.fill"
        }
    }
}

@MainActor
@Observable
final class MonetizationManager {
//    static let proEnabledByDefault = true
    static let freeDailyMessageLimit = 5

    private enum StorageKey {
        // Key name predates the daily reset; kept for continuity.
        static let freeInstallMessageCount = "monetization.freeInstallMessageCount"
        static let freeMessageCountDay = "monetization.freeMessageCountDay"
        static let didWarnAtThreeLeftOnInstall = "monetization.didWarnAtThreeLeftOnInstall"
        static let cachedPurchasedProductIDs = "monetization.cachedPurchasedProductIDs"
        #if DEBUG
        static let debugProEnabled = "monetization.debugProEnabled"
        #endif
    }

    static let productIDs = [
        "ownai.pro.monthly.v2",
        "ownai.pro.yearly.v2",
        "ownai.pro.lifetime"
    ]

    static let freeModelIDs: Set<String> = [
        ModelInfo.appleFoundation.id,
        ModelInfo.gemma2_2b_4bit.id,
        // The bundled starter model must stay free: it is the instant
        // first-run experience on devices without Apple Intelligence.
        ModelInfo.qwen3_0_6b_4bit.id
    ]

    var products: [Product] = []
    var purchasedProductIDs: Set<String> = []
    var isLoadingProducts = false
    var isProcessingPurchase = false
    var purchaseErrorMessage: String?
    var freeInstallMessageCount = 0
    var didWarnAtThreeLeftOnInstall = false
    /// Start of the day the current count belongs to; nil before the first
    /// counted message (or for users upgrading from the per-install scheme,
    /// who get a fresh allowance).
    private var freeMessageCountDay: Date?
    #if DEBUG
    var debugProEnabled = false {
        didSet {
            defaults.set(debugProEnabled, forKey: StorageKey.debugProEnabled)
        }
    }
    #endif



    @ObservationIgnored
    private var updatesTask: Task<Void, Never>?

    @ObservationIgnored
    private let defaults = UserDefaults.standard



    var hasPro: Bool {
        #if DEBUG
        return debugProEnabled || !purchasedProductIDs.isEmpty
        #else
        return !purchasedProductIDs.isEmpty
        #endif

    }

    init() {
        freeInstallMessageCount = defaults.integer(forKey: StorageKey.freeInstallMessageCount)
        didWarnAtThreeLeftOnInstall = defaults.bool(forKey: StorageKey.didWarnAtThreeLeftOnInstall)
        freeMessageCountDay = defaults.object(forKey: StorageKey.freeMessageCountDay) as? Date
        resetDailyAllowanceIfNeeded()
        purchasedProductIDs = loadCachedPurchasedProductIDs()
        #if DEBUG
        debugProEnabled = defaults.bool(forKey: StorageKey.debugProEnabled)
        #endif
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
        // Stated rather than left to the freeModelIDs fallback: importing your
        // own model is a Pro capability, and that should be a decision in the
        // code rather than a side effect of an ID not being on a list.
        if model.isImported { return true }
        return !Self.freeModelIDs.contains(model.id)
    }

    func canUse(_ feature: PremiumFeature) -> Bool {
        switch feature {
        case .unlimitedMessages, .allModels, .advancedPersonality, .unlimitedDocuments, .voiceMode, .imageInput,
             .savedPrompts, .conversationExport, .chatFolders, .importedModels:
            return hasPro
        }
    }

    /// True when the stored count belongs to today. When it doesn't, the
    /// counters read as zero even before the lazy reset persists — so a user
    /// blocked at 23:59 is unblocked at midnight without any mutation.
    private var isCountFromToday: Bool {
        guard let freeMessageCountDay else { return false }
        return Calendar.current.isDateInToday(freeMessageCountDay)
    }

    var freeMessagesUsedToday: Int {
        isCountFromToday ? freeInstallMessageCount : 0
    }

    var freeMessagesRemainingToday: Int {
        max(0, Self.freeDailyMessageLimit - freeMessagesUsedToday)
    }

    var hasReachedFreeDailyMessageLimit: Bool {
        !hasPro && freeMessagesUsedToday >= Self.freeDailyMessageLimit
    }

    var shouldShowThreeMessagesLeftWarning: Bool {
        !hasPro && freeMessagesRemainingToday == 3 && !(isCountFromToday && didWarnAtThreeLeftOnInstall)
    }

    /// Clears the counter and warning flag when the stored count belongs to a
    /// previous day (or to the old per-install scheme, which stored no day).
    private func resetDailyAllowanceIfNeeded() {
        guard !isCountFromToday else { return }
        freeInstallMessageCount = 0
        didWarnAtThreeLeftOnInstall = false
        freeMessageCountDay = Calendar.current.startOfDay(for: Date.now)
        defaults.set(freeInstallMessageCount, forKey: StorageKey.freeInstallMessageCount)
        defaults.set(didWarnAtThreeLeftOnInstall, forKey: StorageKey.didWarnAtThreeLeftOnInstall)
        defaults.set(freeMessageCountDay, forKey: StorageKey.freeMessageCountDay)
    }

    /// Returns true when the message consumed one of today's free messages.
    @discardableResult
    func registerFreeMessageIfNeeded(for messageText: String = "") -> Bool {
        guard !hasPro else { return false }
        resetDailyAllowanceIfNeeded()
        // Don't spend the small free allowance on greetings and
        // acknowledgements — let the limit arrive after real use, not before.
        let trimmed = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed.count < 25 {
            return false
        }
        guard freeInstallMessageCount < Self.freeDailyMessageLimit else { return false }
        freeInstallMessageCount += 1
        defaults.set(freeInstallMessageCount, forKey: StorageKey.freeInstallMessageCount)
        return true
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

    private var secureCacheURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return docs.appendingPathComponent("monetization_cache.secure")
    }

    private func loadCachedPurchasedProductIDs() -> Set<String> {
        if let decoded = try? SecureFileStore.load([String].self, from: secureCacheURL) {
            return Set(decoded)
        }
        return []
    }

    private func cachePurchasedProductIDs(_ productIDs: Set<String>) {
        let encodedIDs = Array(productIDs).sorted()
        try? SecureFileStore.save(encodedIDs, to: secureCacheURL)
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
