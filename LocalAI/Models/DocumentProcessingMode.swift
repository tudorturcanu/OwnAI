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
            return String(localized: "Reads the beginning of a PDF. Faster and uses less storage.")
        case .highQuality:
            return String(localized: "Reads more of a PDF and keeps more text for better answers.")
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
