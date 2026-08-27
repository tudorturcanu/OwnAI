import SwiftUI
import UIKit

struct DocumentSourceDrawerView: View {
    @Environment(\.dismiss) private var dismiss

    let document: ConversationDocument
    /// Section titles the last answer's retrieval used (parsed from the reply's
    /// source titles). Matching cards get a badge so the reader can jump from
    /// an answer to the exact passages behind it. Empty when the sheet is
    /// opened from the attachment chip rather than from a reply.
    var highlightedSectionTitles: Set<String> = []

    @State private var isPreviewingOriginal = false

    /// The retained copy of the imported file, when there is one. Documents
    /// imported before originals were kept — and any whose copy failed — have
    /// no file to open and simply don't show the button.
    private var originalFileURL: URL? {
        DocumentManager.originalFileURL(for: document)
    }

    private var extractedPageCountText: String {
        if document.totalPages == 0 {
            return String(localized: "Text document")
        }

        if document.extractedPages == document.totalPages {
            return document.totalPages == 1
                ? String(localized: "1 page")
                : String(format: String(localized: "%lld pages", defaultValue: "%lld pages"), Int64(document.totalPages))
        }

        return String(
            format: String(localized: "%lld of %lld pages", defaultValue: "%lld of %lld pages"),
            Int64(document.extractedPages),
            Int64(document.totalPages)
        )
    }

    private var fileSizeText: String {
        ByteCountFormatter.string(fromByteCount: document.fileSize, countStyle: .file)
    }

    private var storageNote: String {
        document.isTrimmed
            ? String(localized: "Stored locally for this chat, trimmed to fit")
            : String(localized: "Stored locally for this chat")
    }

    private var provenanceLabel: String {
        document.textOrigin.accessibilityLabel
    }

    private var hasOCRContent: Bool {
        document.textOrigin != .native
    }

    private var ocrWarningText: String? {
        document.ocrWarningText
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    summaryCard

                    if document.sections.isEmpty {
                        sectionCard(
                            title: String(localized: "Document excerpt"),
                            snippet: document.content,
                            isOCR: hasOCRContent,
                            textToCopy: document.content,
                            isHighlighted: false
                        )
                    } else {
                        LazyVStack(spacing: 12) {
                            ForEach(Array(document.sections.enumerated()), id: \.offset) { index, section in
                                let snippet = snippet(for: section)
                                sectionCard(
                                    title: section.title,
                                    snippet: snippet,
                                    isOCR: sectionIsOCR(section),
                                    textToCopy: text(for: section),
                                    sectionNumber: index + 1,
                                    isHighlighted: highlightedSectionTitles.contains(section.title)
                                )
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 28)
            }
            .background(Color.adaptive(white: 0.96))
            .navigationTitle(String(localized: "Document Sources"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Done")) {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        copyToClipboard(document.content)
                    } label: {
                        Label(String(localized: "Copy All"), systemImage: "doc.on.doc")
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.blue.opacity(0.14), Color.cyan.opacity(0.10)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 58, height: 58)

                    Image(systemName: document.iconName)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.blue)
                        .accessibilityHidden(true)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(document.name)
                        .font(.headline)
                        .foregroundStyle(Color.adaptive(white: 0.12))
                        .lineLimit(2)

                    Text(provenanceLabel)
                        .font(.subheadline)
                        .foregroundStyle(Color.adaptive(white: 0.45))
                        .lineLimit(1)
                }
            }

            if let originalFileURL {
                Button {
                    isPreviewingOriginal = true
                } label: {
                    Label(String(localized: "Open Original"), systemImage: "doc.text.magnifyingglass")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                .sheet(isPresented: $isPreviewingOriginal) {
                    DocumentPreviewSheet(
                        url: originalFileURL,
                        title: document.name,
                        onClose: { isPreviewingOriginal = false }
                    )
                    .ignoresSafeArea()
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                LabeledContent(String(localized: "Source span"), value: extractedPageCountText)
                LabeledContent(String(localized: "File size"), value: fileSizeText)
                LabeledContent(String(localized: "Storage"), value: storageNote)
                LabeledContent(String(localized: "Text source"), value: provenanceLabel)
            }
            .font(.subheadline)
            .foregroundStyle(Color.adaptive(white: 0.25))

            if hasOCRContent {
                HStack(spacing: 8) {
                    Image(systemName: "sparkle.magnifyingglass")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text(String(localized: "OCR was used for at least part of this document."))
                        .font(.caption)
                        .foregroundStyle(Color.adaptive(white: 0.48))
                }
                .padding(.top, 2)
            }

            if let ocrWarningText {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text(ocrWarningText)
                        .font(.caption)
                        .foregroundStyle(Color.adaptive(white: 0.45))
                }
                .padding(12)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(16)
        .background(Color.adaptiveCard)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.03), radius: 6, y: 3)
    }

    /// The page badge shown beside a section title. PDF sections are already
    /// titled "Page 3" (or "Page 3 (OCR)") by the extractor, so a badge would
    /// just repeat the heading; it only earns its place on documents whose
    /// sections carry real titles. The badge also can't be trusted to name the
    /// page when it does duplicate: it counts sections, and a page that yielded
    /// no text produces none, which shifts every number after it.
    private func pageBadgeText(title: String, sectionNumber: Int?) -> String? {
        guard let sectionNumber else { return nil }
        let label = String(
            format: String(localized: "Page %lld", defaultValue: "Page %lld"),
            Int64(sectionNumber)
        )
        guard !title.localizedCaseInsensitiveContains(label) else { return nil }
        return label
    }

    private func sectionCard(
        title: String,
        snippet: String,
        isOCR: Bool,
        textToCopy: String,
        sectionNumber: Int? = nil,
        isHighlighted: Bool = false
    ) -> some View {
        let pageBadge = pageBadgeText(title: title, sectionNumber: sectionNumber)
        return VStack(alignment: .leading, spacing: 12) {
            if isHighlighted {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .accessibilityHidden(true)
                    Text(String(localized: "Used in answer"))
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.blue)
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(Color.adaptive(white: 0.12))
                            .lineLimit(2)

                        if let pageBadge {
                            Text(pageBadge)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.adaptive(white: 0.48))
                        }
                    }

                    if isOCR {
                        Text(String(localized: "OCR"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.12), in: Capsule())
                    }
                }

                Spacer(minLength: 0)
            }

            Text(snippet.isEmpty ? String(localized: "No readable text was extracted from this page.") : snippet)
                .font(.callout)
                .foregroundStyle(Color.adaptive(white: 0.25))
                .lineLimit(5)
                .multilineTextAlignment(.leading)

            HStack(spacing: 16) {
                NavigationLink {
                    DocumentSourceTextView(
                        title: title,
                        subtitle: pageBadge,
                        text: textToCopy,
                        isOCR: isOCR
                    )
                } label: {
                    Label(String(localized: "Open"), systemImage: "arrow.up.forward.square")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)

                Button {
                    copyToClipboard(textToCopy)
                } label: {
                    Label(String(localized: "Copy Page Text"), systemImage: "doc.on.doc")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(.blue)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isOCR ? Color.orange.opacity(0.06) : Color.blue.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(
                            isHighlighted ? Color.blue.opacity(0.55) : (isOCR ? Color.orange.opacity(0.18) : Color.blue.opacity(0.14)),
                            lineWidth: isHighlighted ? 1.5 : 1
                        )
                )
        )
    }

    private func sectionIsOCR(_ section: DocumentSection) -> Bool {
        hasOCRContent || section.title.localizedCaseInsensitiveContains("OCR")
    }

    private func text(for section: DocumentSection) -> String {
        guard !document.content.isEmpty else { return "" }

        let lowerBound = max(0, min(section.lowerBound, document.content.count))
        let upperBound = max(lowerBound, min(section.upperBound, document.content.count))
        guard upperBound > lowerBound else { return "" }

        let startIndex = document.content.index(document.content.startIndex, offsetBy: lowerBound)
        let endIndex = document.content.index(document.content.startIndex, offsetBy: upperBound)
        return String(document.content[startIndex..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func snippet(for section: DocumentSection) -> String {
        let text = text(for: section)
        guard !text.isEmpty else { return "" }

        let compacted = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let maxLength = 280
        guard compacted.count > maxLength else { return compacted }

        let endIndex = compacted.index(compacted.startIndex, offsetBy: maxLength)
        return String(compacted[..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    private func copyToClipboard(_ string: String) {
        UIPasteboard.general.string = string
    }
}

private struct DocumentSourceTextView: View {
    let title: String
    let subtitle: String?
    let text: String
    let isOCR: Bool

    @State private var isReflowed: Bool

    init(title: String, subtitle: String?, text: String, isOCR: Bool) {
        self.title = title
        self.subtitle = subtitle
        self.text = text
        self.isOCR = isOCR
        self._isReflowed = State(initialValue: isOCR)
    }

    private var displayText: String {
        let rawText = text.isEmpty ? String(localized: "No readable text was extracted from this page.") : text
        if isReflowed {
            return reflowText(rawText)
        } else {
            return rawText
        }
    }

    private func reflowText(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")

        let paragraphNormalizedRegex = try? NSRegularExpression(pattern: "\\n[ \\t]*\\n", options: [])
        let cleanedText = paragraphNormalizedRegex?.stringByReplacingMatches(
            in: normalized,
            options: [],
            range: NSRange(normalized.startIndex..., in: normalized),
            withTemplate: "\n\n"
        ) ?? normalized

        let paragraphs = cleanedText.components(separatedBy: "\n\n")

        let processedParagraphs = paragraphs.map { paragraph -> String in
            let hyphenatedRegex = try? NSRegularExpression(
                pattern: "(\\p{L})-\\s*\\n\\s*(\\p{L})",
                options: []
            )
            let paragraphWithNoHyphens = hyphenatedRegex?.stringByReplacingMatches(
                in: paragraph,
                options: [],
                range: NSRange(paragraph.startIndex..., in: paragraph),
                withTemplate: "$1$2"
            ) ?? paragraph

            let newlineRegex = try? NSRegularExpression(
                pattern: "\\s*\\n\\s*",
                options: []
            )
            let reflowedParagraph = newlineRegex?.stringByReplacingMatches(
                in: paragraphWithNoHyphens,
                options: [],
                range: NSRange(paragraphWithNoHyphens.startIndex..., in: paragraphWithNoHyphens),
                withTemplate: " "
            ) ?? paragraphWithNoHyphens

            return reflowedParagraph.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return processedParagraphs.joined(separator: "\n\n")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.adaptive(white: 0.48))
                    }

                    Text(title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color.adaptive(white: 0.12))

                    if isOCR {
                        Text(String(localized: "OCR"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.12), in: Capsule())
                    }
                }

                Text(displayText)
                    .font(.body)
                    .foregroundStyle(Color.adaptive(white: 0.22))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 28)
        }
        .background(Color.adaptive(white: 0.96))
        .navigationTitle(String(localized: "Source Text"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 16) {
                    Button {
                        isReflowed.toggle()
                    } label: {
                        Label(
                            isReflowed ? String(localized: "Original Layout") : String(localized: "Reflow Text"),
                            systemImage: isReflowed ? "text.alignleft" : "text.justify"
                        )
                    }

                    Button {
                        UIPasteboard.general.string = displayText
                    } label: {
                        Label(String(localized: "Copy All"), systemImage: "doc.on.doc")
                    }
                    .disabled(text.isEmpty)
                }
            }
        }
    }
}
