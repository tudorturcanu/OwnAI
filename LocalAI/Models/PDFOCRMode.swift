import Foundation

enum PDFOCRMode: String, CaseIterable, Identifiable, Sendable {
    case preferNativeText
    case ocrScannedPages
    case ocrAllPages

    static let storageKey = "pdfOCRMode"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .preferNativeText:
            return String(localized: "Prefer Native Text")
        case .ocrScannedPages:
            return String(localized: "OCR Scanned Pages")
        case .ocrAllPages:
            return String(localized: "OCR All Pages")
        }
    }

    var subtitle: String {
        switch self {
        case .preferNativeText:
            return String(localized: "Use the PDF text layer first, then OCR only when needed.")
        case .ocrScannedPages:
            return String(localized: "Run OCR on pages that look like scans or weak text exports.")
        case .ocrAllPages:
            return String(localized: "Run OCR on every page, even when native text exists.")
        }
    }
}
