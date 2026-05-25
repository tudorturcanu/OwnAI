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
            return String(localized: "Optimize document uploads for speed and lower storage use.")
        case .highQuality:
            return String(localized: "Extract more pages and keep more text for better document answers.")
        }
    }

    nonisolated var maxPDFPages: Int {
        switch self {
        case .fast:
            return 5
        case .highQuality:
            return 50
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
