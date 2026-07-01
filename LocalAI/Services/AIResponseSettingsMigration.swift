import Foundation

enum AIResponseSettingsMigration {
    private static let legacyMigrationKey = "didMigrateFullResponseDefaults"
    private static let maxTokensMigrationKey = "didMigrateMaxTokensDefaultTo2048"
    private static let responseCharacterLimitMigrationKey = "didMigrateResponseCharacterLimitDefaultToUnlimited"
    private static let systemPromptMigrationKey = "didMigrateDefaultSystemPromptCompletion"

    static func migrateIfNeeded(defaults: UserDefaults = .standard) {
        migrateMaxTokensIfNeeded(defaults: defaults)
        migrateResponseCharacterLimitIfNeeded(defaults: defaults)
        migrateSystemPromptIfNeeded(defaults: defaults)

        // Keep the legacy marker set for older app versions, but do not use it
        // to block newer one-time migrations.
        defaults.set(true, forKey: legacyMigrationKey)
    }

    private static func migrateMaxTokensIfNeeded(defaults: UserDefaults) {
        guard !defaults.bool(forKey: maxTokensMigrationKey) else { return }

        if defaults.object(forKey: "maxTokens") == nil || defaults.integer(forKey: "maxTokens") <= 512 {
            defaults.set(AIResponseDefaults.maxTokens, forKey: "maxTokens")
        }

        defaults.set(true, forKey: maxTokensMigrationKey)
    }

    private static func migrateResponseCharacterLimitIfNeeded(defaults: UserDefaults) {
        guard !defaults.bool(forKey: responseCharacterLimitMigrationKey) else { return }

        if defaults.object(forKey: "responseCharacterLimit") == nil || defaults.integer(forKey: "responseCharacterLimit") == 1000 {
            defaults.set(AIResponseDefaults.responseCharacterLimit, forKey: "responseCharacterLimit")
        }

        defaults.set(true, forKey: responseCharacterLimitMigrationKey)
    }

    private static func migrateSystemPromptIfNeeded(defaults: UserDefaults) {
        guard !defaults.bool(forKey: systemPromptMigrationKey) else { return }

        if defaults.string(forKey: "systemPrompt") == "You are a helpful AI assistant." {
            defaults.set(AIResponseDefaults.defaultSystemPrompt, forKey: "systemPrompt")
        }

        defaults.set(true, forKey: systemPromptMigrationKey)
    }
}
