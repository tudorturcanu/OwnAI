//
//  RenderableCodeBlockView.swift
//  LocalAI
//
//  Created by Tudor on 19.08.2026.
//

import SwiftUI
import WebKit

/// Code block for `svg`/`html` fences that can flip between the raw code and a
/// rendered preview. While the reply is still streaming it behaves exactly like
/// a normal code block; once the closing tag has arrived the preview takes over.
struct RenderableCodeBlockView: View {
    let content: String
    let language: String?
    let theme: CodeTheme
    let isStreaming: Bool
    let textScale: Double

    @State private var showsCode = false
    @State private var showsExpandedPreview = false

    private static let lightHaptic = UIImpactFeedbackGenerator(style: .light)

    /// Fences we can render. Untagged/`xml` fences qualify only when the body
    /// is actually an `<svg>` root, so ordinary XML keeps its plain code block.
    static func isPreviewable(language: String?, content: String) -> Bool {
        switch language?.lowercased() {
        case "svg", "html":
            return true
        case nil, "xml":
            return content.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<svg")
        default:
            return false
        }
    }

    /// The preview only makes sense once the document is complete — rendering a
    /// half-streamed tag soup would flash broken layouts on every token tick.
    private var canPreview: Bool {
        guard !isStreaming else { return false }
        let lowered = content.lowercased()
        return lowered.contains("</svg>") || lowered.contains("</html>") || lowered.contains("</body>")
    }

    private var showsPreview: Bool { canPreview && !showsCode }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(language?.lowercased() ?? "svg")
                    .font(.caption.bold())
                    .foregroundStyle(theme.foreground.opacity(0.8))
                Spacer()
                if canPreview {
                    Button {
                        showsCode.toggle()
                        Self.lightHaptic.impactOccurred()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: showsPreview ? "chevron.left.forwardslash.chevron.right" : "photo")
                                .font(.caption2)
                            Text(showsPreview ? "Code" : "Preview")
                                .font(.caption.bold())
                        }
                        .foregroundStyle(theme.foreground)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(theme.background)
                        .clipShape(Capsule())
                        .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
                    }
                    .buttonStyle(.plain)
                    .frame(minHeight: 44)
                }
                Button {
                    UIPasteboard.general.string = content
                    Self.lightHaptic.impactOccurred()
                    UIAccessibility.post(notification: .announcement, argument: String(localized: "Copied"))
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc")
                            .font(.caption2)
                        Text("Copy")
                            .font(.caption.bold())
                    }
                    .foregroundStyle(theme.foreground)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(theme.background)
                    .clipShape(Capsule())
                    .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
                }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(theme.headerBackground)

            if showsPreview {
                // A diagram larger than this box used to be unreadable, with
                // no way in but copying the source. Tapping opens it full
                // screen with pinch zoom.
                Button {
                    showsExpandedPreview = true
                    Self.lightHaptic.impactOccurred()
                } label: {
                    HTMLPreviewWebView(html: documentHTML)
                        .frame(height: 280)
                        .background(Color.white)
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(8)
                                .background(.black.opacity(0.55), in: Circle())
                                .padding(10)
                                .accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Expand preview"))
                .accessibilityHint(String(localized: "Opens the rendered preview full screen with zoom."))
                .fullScreenCover(isPresented: $showsExpandedPreview) {
                    ExpandedPreviewSheet(html: documentHTML, source: content)
                }
            } else {
                ScrollView(.horizontal, showsIndicators: true) {
                    AsyncCodeBlockView(
                        content: content,
                        language: language,
                        theme: theme,
                        isStreaming: isStreaming,
                        textScale: textScale
                    )
                }
                .background(theme.background)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(theme.borderColor, lineWidth: 1)
        )
        .padding(.vertical, 8)
    }

    /// Small models routinely emit slightly broken SVG — an attribute quote that
    /// never closes (`viewBox="0 0 200 300<rect`), or `/>` collapsed to `/`
    /// (`fill="red"/<circle`). WebKit's XML-ish SVG parsing gives up on those,
    /// so a single linear pass closes any tag that is still open when the next
    /// `<` arrives (finishing a dangling quote first). Quotes only toggle
    /// inside tags, so `<` and `"` in text content stay untouched.
    static func repairedSVG(_ raw: String) -> String {
        var output = ""
        output.reserveCapacity(raw.count)
        var inTag = false
        var inQuote = false
        for character in raw {
            if inTag {
                if character == "<" {
                    if inQuote { output.append("\""); inQuote = false }
                    output.append(">")
                    output.append(character)
                    continue
                }
                if character == "\"" { inQuote.toggle() }
                if character == ">", !inQuote { inTag = false }
                output.append(character)
            } else {
                if character == "<" { inTag = true }
                output.append(character)
            }
        }
        if inTag {
            if inQuote { output.append("\"") }
            output.append(">")
        }
        return output
    }

    /// Full HTML documents pass through untouched; bare SVG (or an HTML
    /// fragment) is wrapped in a minimal centered page. The canvas is always
    /// white so model-chosen colors look the same in light and dark mode.
    private var documentHTML: String {
        var trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("<svg") {
            trimmed = Self.repairedSVG(trimmed)
        }
        if trimmed.lowercased().contains("<html") { return trimmed }
        return """
        <!doctype html><html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=6, user-scalable=yes">
        <style>
        html, body { margin: 0; height: 100%; background: #ffffff; }
        body { display: flex; align-items: center; justify-content: center; padding: 12px; box-sizing: border-box; }
        svg { max-width: 100%; max-height: 100%; height: auto; }
        </style>
        </head><body>\(trimmed)</body></html>
        """
    }
}

/// Full-screen, zoomable version of the inline preview.
private struct ExpandedPreviewSheet: View {
    let html: String
    let source: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            HTMLPreviewWebView(html: html, allowsZoom: true)
                .background(Color.white)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(String(localized: "Preview"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        SheetCloseButton { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            UIPasteboard.general.string = source
                            UIAccessibility.post(notification: .announcement, argument: String(localized: "Copied"))
                        } label: {
                            Label(String(localized: "Copy Source"), systemImage: "doc.on.doc")
                        }
                        .accessibilityLabel(String(localized: "Copy source"))
                    }
                }
        }
    }
}

/// Local-only WKWebView host for the preview. Scripts stay disabled — the
/// document is model-generated, and SVG/static HTML never needs them.
private struct HTMLPreviewWebView: UIViewRepresentable {
    let html: String
    /// Inline previews are fixed boxes inside a scrolling transcript, so they
    /// must not capture scroll or pinch; the full-screen sheet wants both.
    var allowsZoom: Bool = false

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedHTML: String?

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            // `.other` is the loadHTMLString of the document itself. Anything
            // else — a tapped link, a redirect — would take the preview off the
            // device, so it is refused.
            decisionHandler(navigationAction.navigationType == .other ? .allow : .cancel)
        }
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .white
        webView.scrollView.isScrollEnabled = allowsZoom
        webView.scrollView.backgroundColor = .white
        if allowsZoom {
            webView.scrollView.minimumZoomScale = 1
            webView.scrollView.maximumZoomScale = 6
            webView.scrollView.bouncesZoom = true
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedHTML != html else { return }
        context.coordinator.loadedHTML = html
        webView.loadHTMLString(html, baseURL: nil)
    }
}

#Preview {
    RenderableCodeBlockView(
        content: """
        <svg viewBox="0 0 200 200" xmlns="http://www.w3.org/2000/svg">
          <rect width="200" height="200" fill="#0b1e3a"/>
          <circle cx="150" cy="50" r="20" fill="#f5d76e"/>
          <polygon points="100,30 120,110 80,110" fill="#e74c3c"/>
        </svg>
        """,
        language: "svg",
        theme: .defaultTheme,
        isStreaming: false,
        textScale: 1.0
    )
    .padding()
}
