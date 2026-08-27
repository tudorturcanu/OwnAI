//
//  DocumentPreviewSheet.swift
//  LocalAI
//

import SwiftUI
import QuickLook

/// Presents the retained original of an imported document with QuickLook, which
/// renders PDFs, rich text, and Office formats without the app parsing them.
///
/// The file is a copy inside the app container, not the URL the user picked:
/// that one is security-scoped and stops being readable when import ends. The
/// copy is made during import by `DocumentManager.storeOriginalFile(at:)`.
struct DocumentPreviewSheet: UIViewControllerRepresentable {
    let url: URL
    /// The document's own name. Stored copies are named by UUID to avoid
    /// collisions, so without this QuickLook titles the preview with the raw
    /// storage name.
    let title: String
    let onClose: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(item: PreviewItem(url: url, title: title), onClose: onClose)
    }

    func makeUIViewController(context: Context) -> UINavigationController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        // QuickLook only supplies its own dismiss control when it presents
        // itself; hosted inside a SwiftUI sheet the preview would otherwise have
        // no way out but the drag-to-dismiss gesture.
        controller.navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: context.coordinator,
            action: #selector(Coordinator.close)
        )
        return UINavigationController(rootViewController: controller)
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {
        context.coordinator.item = PreviewItem(url: url, title: title)
        context.coordinator.onClose = onClose
        (uiViewController.viewControllers.first as? QLPreviewController)?.reloadData()
    }

    /// Pairs the stored file with the name the user knows it by.
    final class PreviewItem: NSObject, QLPreviewItem {
        let previewItemURL: URL?
        let previewItemTitle: String?

        init(url: URL, title: String) {
            self.previewItemURL = url
            self.previewItemTitle = title
        }
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var item: PreviewItem
        var onClose: () -> Void

        init(item: PreviewItem, onClose: @escaping () -> Void) {
            self.item = item
            self.onClose = onClose
        }

        @objc func close() {
            onClose()
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(
            _ controller: QLPreviewController,
            previewItemAt index: Int
        ) -> QLPreviewItem {
            item
        }
    }
}
