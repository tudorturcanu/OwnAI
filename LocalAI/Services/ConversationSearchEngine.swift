//
//  ConversationSearchEngine.swift
//  LocalAI
//
//  Token-based search over stored conversations, with match excerpts.
//

import Foundation

/// Searches chat history off the main actor and returns, per conversation, how
/// many messages matched plus a short excerpt around the first match.
///
/// Matching is case- and diacritic-insensitive and requires every query token to
/// appear in the same message (or in the conversation title), so a multi-word
/// query such as "tax invoice" filters instead of demanding an exact substring.
nonisolated enum ConversationSearchEngine {

    struct Hit: Identifiable, Sendable, Equatable {
        let conversationID: UUID
        /// Number of messages containing every query token.
        let matchCount: Int
        let titleMatched: Bool
        /// Excerpt around the first match, or the last message when only the title matched.
        let snippet: String
        /// Character offsets into `snippet` that should be highlighted.
        let highlightRanges: [Range<Int>]
        let snippetRole: ChatMessage.MessageRole?
        /// First message containing every token, so the chat can open scrolled to it.
        let firstMatchMessageID: UUID?

        var id: UUID { conversationID }
    }

    private static let compareOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
    private static let maximumTokenCount = 8
    /// Characters of leading context kept before the first match.
    private static let snippetLeadingContext = 32
    private static let maximumSnippetLength = 160

    // MARK: - Query parsing

    /// Splits a raw query into deduplicated, non-empty search tokens.
    static func tokens(for query: String) -> [String] {
        var seen: Set<String> = []
        var tokens: [String] = []
        for rawToken in query.split(whereSeparator: { $0.isWhitespace }) {
            let token = String(rawToken)
            guard seen.insert(token.lowercased()).inserted else { continue }
            tokens.append(token)
            if tokens.count == maximumTokenCount { break }
        }
        return tokens
    }

    // MARK: - Search

    /// Returns a hit for every conversation matching `query`, keyed by conversation ID.
    ///
    /// Cooperatively cancellable: callers running this from a detached task can
    /// abandon a stale keystroke without finishing the scan.
    static func search(query: String, in conversations: [ChatConversation]) -> [UUID: Hit] {
        let tokens = tokens(for: query)
        guard !tokens.isEmpty else { return [:] }

        var hits: [UUID: Hit] = [:]
        hits.reserveCapacity(conversations.count)

        for conversation in conversations {
            if Task.isCancelled { return hits }
            if let hit = hit(for: conversation, tokens: tokens) {
                hits[conversation.id] = hit
            }
        }
        return hits
    }

    private static func hit(for conversation: ChatConversation, tokens: [String]) -> Hit? {
        let titleMatched = containsAllTokens(conversation.title, tokens: tokens)

        var matchCount = 0
        var firstMatch: ChatMessage?
        for message in conversation.messages where containsAllTokens(message.content, tokens: tokens) {
            matchCount += 1
            if case .none = firstMatch { firstMatch = message }
        }

        guard titleMatched || matchCount > 0 else { return nil }

        // A title-only match still deserves a preview, so fall back to the last
        // message the way an unfiltered row would show it.
        let previewMessage = firstMatch ?? conversation.messages.last
        let snippetTokens: [String]
        switch firstMatch {
        case .some:
            snippetTokens = tokens
        case .none:
            snippetTokens = []
        }
        let excerpt = snippet(
            for: previewMessage?.content ?? "",
            tokens: snippetTokens
        )

        return Hit(
            conversationID: conversation.id,
            matchCount: matchCount,
            titleMatched: titleMatched,
            snippet: excerpt.text,
            highlightRanges: excerpt.highlightRanges,
            snippetRole: previewMessage?.role,
            firstMatchMessageID: firstMatch?.id
        )
    }

    /// True when `haystack` contains every token, ignoring case and diacritics.
    static func containsAllTokens(_ haystack: String, tokens: [String]) -> Bool {
        guard !haystack.isEmpty else { return false }
        for token in tokens where haystack.range(of: token, options: compareOptions) == nil {
            return false
        }
        return true
    }

    // MARK: - Excerpts

    /// Builds a single-line excerpt centred on the first token occurrence and
    /// reports the highlight ranges as character offsets into the result.
    ///
    /// Only the window around the match is copied, so a multi-page message costs
    /// the same as a one-line one.
    static func snippet(for content: String, tokens: [String]) -> (text: String, highlightRanges: [Range<Int>]) {
        guard !content.isEmpty else { return ("", []) }

        let anchor = tokens
            .compactMap { content.range(of: $0, options: compareOptions)?.lowerBound }
            .min() ?? content.startIndex

        var windowStart = content.index(anchor, offsetBy: -snippetLeadingContext, limitedBy: content.startIndex)
            ?? content.startIndex
        windowStart = wordBoundary(before: windowStart, in: content)

        // Collapsing whitespace can only shrink the window, so read extra
        // characters up front rather than going back for more afterwards.
        let windowEnd = content.index(
            windowStart,
            offsetBy: maximumSnippetLength * 2,
            limitedBy: content.endIndex
        ) ?? content.endIndex

        var text = singleLine(content[windowStart..<windowEnd])
        var isTruncated = windowEnd < content.endIndex
        if text.count > maximumSnippetLength {
            text = String(text.prefix(maximumSnippetLength))
            isTruncated = true
        }
        if text.isEmpty { return ("", []) }

        if windowStart > content.startIndex { text = "…" + text }
        if isTruncated { text += "…" }

        return (text, highlightRanges(in: text, tokens: tokens))
    }

    /// Collapses runs of whitespace so excerpts stay readable on one line.
    private static func singleLine(_ content: Substring) -> String {
        var result = ""
        result.reserveCapacity(content.count)
        var lastWasWhitespace = false
        for character in content {
            if character.isWhitespace {
                if !lastWasWhitespace && !result.isEmpty { result.append(" ") }
                lastWasWhitespace = true
            } else {
                result.append(character)
                lastWasWhitespace = false
            }
        }
        if result.hasSuffix(" ") { result.removeLast() }
        return result
    }

    /// Walks back to the start of the word containing `index` so excerpts do not
    /// begin mid-word. Gives up after a short scan to stay cheap on long runs.
    private static func wordBoundary(before index: String.Index, in text: String) -> String.Index {
        guard index > text.startIndex else { return index }
        var cursor = index
        var steps = 0
        while cursor > text.startIndex, steps < 16 {
            let previous = text.index(before: cursor)
            if text[previous].isWhitespace { return cursor }
            cursor = previous
            steps += 1
        }
        return index
    }

    /// Character-offset ranges of every token occurrence, merged where they overlap.
    private static func highlightRanges(in text: String, tokens: [String]) -> [Range<Int>] {
        guard !tokens.isEmpty else { return [] }

        var ranges: [Range<Int>] = []
        for token in tokens {
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let found = text.range(of: token, options: compareOptions, range: searchStart..<text.endIndex) {
                let lower = text.distance(from: text.startIndex, to: found.lowerBound)
                let upper = text.distance(from: text.startIndex, to: found.upperBound)
                if upper > lower { ranges.append(lower..<upper) }
                searchStart = found.upperBound > found.lowerBound
                    ? found.upperBound
                    : text.index(after: found.lowerBound)
            }
        }

        guard !ranges.isEmpty else { return [] }
        ranges.sort { $0.lowerBound < $1.lowerBound }

        var merged: [Range<Int>] = [ranges[0]]
        for range in ranges.dropFirst() {
            let last = merged[merged.count - 1]
            if range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}
