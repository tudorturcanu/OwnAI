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

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allModels:
            return "All Models"
        case .advancedPersonality:
            return "Advanced Personality"
        case .unlimitedDocuments:
            return "Unlimited Document Chat"
        case .voiceMode:
            return "Conversation Mode"
        case .imageInput:
            return "Image Input"
        }
    }

    var subtitle: String {
        switch self {
        case .allModels:
            return "Unlock the full local model catalog, including higher-quality and specialty models."
        case .advancedPersonality:
            return "Use custom system prompts, response tuning, and deeper control over how the assistant behaves."
        case .unlimitedDocuments:
            return "Attach more than one document per chat and build richer local research workflows."
        case .voiceMode:
            return "Keep the conversation going hands-free with automatic listen and spoken replies."
        case .imageInput:
            return "Attach photos and ask questions about what you see — powered by on-device vision."
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
        }
    }
}

@MainActor
@Observable
final class MonetizationManager {
    static let freeDailyMessageLimitRange = 6...10
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

    @ObservationIgnored
    @AppStorage("monetization.freeDailyMessageCount")
    private var storedFreeDailyMessageCount = 0

    @ObservationIgnored
    @AppStorage("monetization.freeDailyMessageDay")
    private var storedFreeDailyMessageDay = ""

    @ObservationIgnored
    @AppStorage("monetization.didWarnAtThreeLeftToday")
    private var storedDidWarnAtThreeLeftToday = false

    @ObservationIgnored
    @AppStorage("monetization.freeDailyMessageLimit")
    private var storedFreeDailyMessageLimit = 10

    @ObservationIgnored
    @AppStorage("monetization.cachedPurchasedProductIDs")
    private var storedPurchasedProductIDs = ""

    @ObservationIgnored
    private var updatesTask: Task<Void, Never>?

    var hasPro: Bool {
        return !purchasedProductIDs.isEmpty
    }

    init() {
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
            purchaseErrorMessage = "Could not load upgrade options right now."
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
                    purchaseErrorMessage = "Purchase verification failed."
                    return false
                }
                await transaction.finish()
                await refreshEntitlements()
                purchaseErrorMessage = nil
                return true
            case .userCancelled, .pending:
                return false
            @unknown default:
                purchaseErrorMessage = "Purchase could not be completed."
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
            purchaseErrorMessage = "Could not restore purchases right now."
        }
    }

    func isPremiumModel(_ model: ModelInfo) -> Bool {
        !Self.freeModelIDs.contains(model.id)
    }

    func canUse(_ feature: PremiumFeature) -> Bool {
        switch feature {
        case .allModels, .advancedPersonality, .unlimitedDocuments, .voiceMode, .imageInput:
            return hasPro
        }
    }

    var freeMessagesUsedToday: Int {
        refreshDailyCounterIfNeeded()
        return storedFreeDailyMessageCount
    }

    var freeMessagesRemainingToday: Int {
        max(0, freeDailyMessageLimitToday - freeMessagesUsedToday)
    }

    var hasReachedFreeDailyMessageLimit: Bool {
        !hasPro && freeMessagesUsedToday >= freeDailyMessageLimitToday
    }

    var shouldShowThreeMessagesLeftWarning: Bool {
        !hasPro && freeMessagesRemainingToday == 3 && !storedDidWarnAtThreeLeftToday
    }

    func registerFreeMessageIfNeeded() {
        guard !hasPro else { return }
        refreshDailyCounterIfNeeded()
        guard storedFreeDailyMessageCount < freeDailyMessageLimitToday else { return }
        storedFreeDailyMessageCount += 1
    }

    func markThreeMessagesLeftWarningShown() {
        refreshDailyCounterIfNeeded()
        storedDidWarnAtThreeLeftToday = true
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

    private func refreshDailyCounterIfNeeded() {
        let today = Self.dayKey(for: .now)
        if storedFreeDailyMessageDay != today {
            storedFreeDailyMessageDay = today
            storedFreeDailyMessageCount = 0
            storedDidWarnAtThreeLeftToday = false
            storedFreeDailyMessageLimit = Int.random(in: Self.freeDailyMessageLimitRange)
        }
    }

    private var freeDailyMessageLimitToday: Int {
        refreshDailyCounterIfNeeded()
        return storedFreeDailyMessageLimit
    }

    private static func dayKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = .autoupdatingCurrent
        formatter.locale = .autoupdatingCurrent
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
