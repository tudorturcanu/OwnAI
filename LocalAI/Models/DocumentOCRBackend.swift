import Foundation

enum DocumentOCRBackend: String, CaseIterable, Identifiable, Sendable {
    case appleVision
    case glmOCR

    nonisolated static let storageKey = "documentOCRBackend"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appleVision:
            return String(localized: "Apple Vision")
        case .glmOCR:
            return String(localized: "GLM OCR")
        }
    }

    var subtitle: String {
        switch self {
        case .appleVision:
            return String(localized: "Fast built-in OCR with no additional download.")
        case .glmOCR:
            return String(localized: "Enhanced local OCR for complex scans, tables, formulas, and layouts.")
        }
    }

    nonisolated static var current: DocumentOCRBackend {
        DocumentOCRBackend(
            rawValue: UserDefaults.standard.string(forKey: storageKey) ?? appleVision.rawValue
        ) ?? .appleVision
    }
}
