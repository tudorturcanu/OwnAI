import Foundation

enum DocumentExtractionQuality: String, Codable, Sendable {
    case normal
    case weak

    var isWeak: Bool {
        self == .weak
    }

    var warningText: String? {
        switch self {
        case .normal:
            return nil
        case .weak:
            return String(localized: "OCR text looks sparse. The scan may be blurry or low contrast.")
        }
    }
}
