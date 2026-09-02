//
//  ConversationExporter.swift
//  LocalAI
//
//  Formats chat histories as Markdown or plain text for export.
//

import Foundation

nonisolated enum ConversationExporter {

    enum Format {
        case markdown
        case plainText
    }

    // MARK: - Public API

    static func export(
        messages: [ChatMessage],
        title: String,
        format: Format = .markdown
    ) -> String {
        switch format {
        case .markdown:
            return markdownExport(messages: messages, title: title)
        case .plainText:
            return plainTextExport(messages: messages, title: title)
        }
    }

    /// Bundles every conversation into one document so the user can keep an
    /// off-device backup of history that otherwise only exists on this phone.
    ///
    /// Newest first, matching the order shown in History.
    static func exportAll(conversations: [ChatConversation], format: Format = .markdown) -> String {
        let exportable = conversations.filter { conversation in
            conversation.messages.contains { !$0.isStreaming && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }

        switch format {
        case .markdown:
            return markdownArchive(conversations: exportable)
        case .plainText:
            return plainTextArchive(conversations: exportable)
        }
    }

    static func archiveFileName(format: Format) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let ext = format == .markdown ? "md" : "txt"
        return "Own AI Chats \(formatter.string(from: Date())).\(ext)"
    }

    static func fileName(title: String, format: Format) -> String {
        let sanitized = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .prefix(60)
        let base = sanitized.isEmpty ? "Conversation" : String(sanitized)
        let ext = format == .markdown ? "md" : "txt"
        return "\(base).\(ext)"
    }

    // MARK: - Formatters

    private static func markdownExport(messages: [ChatMessage], title: String) -> String {
        var lines: [String] = []
        lines.append("# \(title)")
        lines.append("")
        lines.append("*Exported from Own AI · \(formattedDate())*")
        lines.append("")
        lines.append("---")
        lines.append("")

        for message in messages where !message.isStreaming {
            let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            switch message.role {
            case .user:
                lines.append("**You**")
            case .assistant:
                lines.append("**AI**")
            }
            lines.append("")
            lines.append(trimmed)
            lines.append("")
            lines.append("---")
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    private static func plainTextExport(messages: [ChatMessage], title: String) -> String {
        var lines: [String] = []
        lines.append(title)
        lines.append("Exported from Own AI · \(formattedDate())")
        lines.append(String(repeating: "─", count: 40))
        lines.append("")

        for message in messages where !message.isStreaming {
            let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            switch message.role {
            case .user:
                lines.append("You:")
            case .assistant:
                lines.append("AI:")
            }
            lines.append(trimmed)
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    private static func markdownArchive(conversations: [ChatConversation]) -> String {
        var lines: [String] = []
        lines.append("# Own AI — Chat Archive")
        lines.append("")
        lines.append("*\(conversations.count) conversations · exported \(formattedDate())*")
        lines.append("")

        for conversation in conversations {
            lines.append("---")
            lines.append("")
            lines.append("## \(conversation.title)")
            lines.append("")
            lines.append("*\(formattedDate(conversation.updatedAt))*")
            lines.append("")

            for message in conversation.messages where !message.isStreaming {
                let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                lines.append(message.role == .user ? "**You**" : "**AI**")
                lines.append("")
                lines.append(trimmed)
                lines.append("")
            }
        }

        return lines.joined(separator: "\n")
    }

    private static func plainTextArchive(conversations: [ChatConversation]) -> String {
        var lines: [String] = []
        lines.append("Own AI — Chat Archive")
        lines.append("\(conversations.count) conversations · exported \(formattedDate())")
        lines.append("")

        for conversation in conversations {
            lines.append(String(repeating: "─", count: 40))
            lines.append(conversation.title)
            lines.append(formattedDate(conversation.updatedAt))
            lines.append("")

            for message in conversation.messages where !message.isStreaming {
                let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                lines.append(message.role == .user ? "You:" : "AI:")
                lines.append(trimmed)
                lines.append("")
            }
        }

        return lines.joined(separator: "\n")
    }

    private static func formattedDate(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
