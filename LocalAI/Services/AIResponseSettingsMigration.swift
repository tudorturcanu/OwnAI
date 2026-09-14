import Foundation

enum AIResponseSettingsMigration {
    private static let legacyMigrationKey = "didMigrateFullResponseDefaults"
    private static let maxTokensMigrationKey = "didMigrateMaxTokensDefaultTo2048"
    private static let responseCharacterLimitMigrationKey = "didMigrateResponseCharacterLimitDefaultToUnlimited"
    private static let systemPromptMigrationKey = "didMigrateDefaultSystemPromptCompletion"
    private static let naturalProsePromptMigrationKey = "didMigrateDefaultSystemPromptNaturalProse"
    private static let tableFormatPromptMigrationKey = "didMigrateDefaultSystemPromptTableFormat"
    private static let deliverAnswerPromptMigrationKey = "didMigrateDefaultSystemPromptDeliverAnswer"
    private static let replyLanguagePromptMigrationKey = "didMigrateSystemPromptReplyLanguage"

    static func migrateIfNeeded(defaults: UserDefaults = .standard) {
        migrateMaxTokensIfNeeded(defaults: defaults)
        migrateResponseCharacterLimitIfNeeded(defaults: defaults)
        migrateSystemPromptIfNeeded(defaults: defaults)
        migrateNaturalProsePromptIfNeeded(defaults: defaults)
        migrateTableFormatPromptIfNeeded(defaults: defaults)
        migrateDeliverAnswerPromptIfNeeded(defaults: defaults)
        migrateReplyLanguagePromptIfNeeded(defaults: defaults)

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

    /// Replaces persisted copies of the earlier defaults with the
    /// natural-prose prompt. Only exact matches of past defaults are
    /// replaced, so a prompt the user customized is never overwritten.
    private static func migrateNaturalProsePromptIfNeeded(defaults: UserDefaults) {
        guard !defaults.bool(forKey: naturalProsePromptMigrationKey) else { return }

        let stored = defaults.string(forKey: "systemPrompt")
        if stored == AIResponseDefaults.legacyBulletedSystemPrompt
            || stored == AIResponseDefaults.legacyCompletionSystemPrompt {
            defaults.set(AIResponseDefaults.defaultSystemPrompt, forKey: "systemPrompt")
        }

        defaults.set(true, forKey: naturalProsePromptMigrationKey)
    }

    /// Replaces the prose default whose exception list left out tables, so an
    /// explicit "reply with a markdown table" is no longer overridden by the
    /// prose rule. As above, only exact past defaults are replaced.
    private static func migrateTableFormatPromptIfNeeded(defaults: UserDefaults) {
        guard !defaults.bool(forKey: tableFormatPromptMigrationKey) else { return }

        let stored = defaults.string(forKey: "systemPrompt")
        if stored == AIResponseDefaults.legacyProseWithoutTablesSystemPrompt
            || stored == AIResponseDefaults.legacyBulletedSystemPrompt
            || stored == AIResponseDefaults.legacyCompletionSystemPrompt {
            defaults.set(AIResponseDefaults.defaultSystemPrompt, forKey: "systemPrompt")
        }

        defaults.set(true, forKey: tableFormatPromptMigrationKey)
    }

    /// Replaces any unmodified past default (shipped or interim dev build)
    /// with the wording that adds the concreteness and no-acknowledgment-stub
    /// rules. Exact matches only, so user-customized prompts are untouched.
    private static func migrateDeliverAnswerPromptIfNeeded(defaults: UserDefaults) {
        guard !defaults.bool(forKey: deliverAnswerPromptMigrationKey) else { return }

        if let stored = defaults.string(forKey: "systemPrompt"),
           AIResponseDefaults.allSupersededSystemPrompts.contains(stored) {
            defaults.set(AIResponseDefaults.defaultSystemPrompt, forKey: "systemPrompt")
        }

        defaults.set(true, forKey: deliverAnswerPromptMigrationKey)
    }

    /// Adds the "reply in the user's language" line (September 2026). Covers
    /// both the default prompt and the built-in personality presets, since
    /// choosing a preset stores its prompt verbatim. Exact matches of past
    /// wordings only, so user-customized prompts are untouched.
    private static func migrateReplyLanguagePromptIfNeeded(defaults: UserDefaults) {
        guard !defaults.bool(forKey: replyLanguagePromptMigrationKey) else { return }

        if let stored = defaults.string(forKey: "systemPrompt") {
            if AIResponseDefaults.allSupersededSystemPrompts.contains(stored) {
                defaults.set(AIResponseDefaults.defaultSystemPrompt, forKey: "systemPrompt")
            } else if let presetPrompt = PersonalityPreset.currentPrompt(replacingLegacyPrompt: stored) {
                defaults.set(presetPrompt, forKey: "systemPrompt")
            }
        }

        defaults.set(true, forKey: replyLanguagePromptMigrationKey)
    }
}
