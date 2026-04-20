//
//  ConversationExporter.swift
//  LocalAI
//
//  Formats chat histories as Markdown or plain text for export.
//

import Foundation

enum ConversationExporter {

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

    private static func formattedDate() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: Date())
    }
}
