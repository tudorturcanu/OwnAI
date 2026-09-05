import Foundation

enum DocumentProcessingMode: String, CaseIterable, Identifiable, Sendable {
    case fast
    case highQuality

    nonisolated static let storageKey = "documentProcessingMode"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fast:
            return String(localized: "Fast")
        case .highQuality:
            return String(localized: "High Quality")
        }
    }

    var subtitle: String {
        switch self {
        case .fast:
            return String(format: String(localized: "Reads the first %lld pages of a PDF. Faster and uses less storage.", defaultValue: "Reads the first %lld pages of a PDF. Faster and uses less storage."), Int64(maxPDFPages))
        case .highQuality:
            return String(format: String(localized: "Reads up to %lld pages of a PDF and keeps more text for better answers.", defaultValue: "Reads up to %lld pages of a PDF and keeps more text for better answers."), Int64(maxPDFPages))
        }
    }

    nonisolated var maxPDFPages: Int {
        switch self {
        case .fast:
            return 5
        case .highQuality:
            return 20
        }
    }

    nonisolated var maxStoredCharacters: Int {
        switch self {
        case .fast:
            return 20_000
        case .highQuality:
            return 120_000
        }
    }
}
