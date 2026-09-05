//
//  MessageTextSelectionSheet.swift
//  LocalAI
//
//  Read-only, selectable view of one message. The transcript rows carry a
//  full-row context-menu overlay, so `.textSelection(.enabled)` never reaches
//  the text itself; this sheet is how a user copies one sentence or one
//  command instead of the whole reply.
//

import SwiftUI
import UIKit

struct MessageTextSelectionSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SelectableTextView(text: text)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(String(localized: "Select Text"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "Done")) { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            UIPasteboard.general.string = text
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                            UIAccessibility.post(notification: .announcement, argument: String(localized: "Copied"))
                        } label: {
                            Label(String(localized: "Copy All"), systemImage: "doc.on.doc")
                        }
                        .accessibilityLabel(String(localized: "Copy all text"))
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// `UITextView` because SwiftUI's `TextEditor` cannot be selectable without
/// also being editable, and a disabled one is not selectable at all.
private struct SelectableTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = true
        view.alwaysBounceVertical = true
        view.backgroundColor = .clear
        view.font = UIFont.preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 24, right: 12)
        view.dataDetectorTypes = [.link]
        view.text = text
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }
    }
}
