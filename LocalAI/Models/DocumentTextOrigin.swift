import Foundation

enum DocumentTextOrigin: String, Codable, Sendable {
    case native
    case ocr
    case mixed

    var badgeTitle: String? {
        switch self {
        case .native:
            return nil
        case .ocr:
            return "OCR"
        case .mixed:
            return "OCR"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .native:
            return "Native text"
        case .ocr:
            return "OCR text"
        case .mixed:
            return "Mixed native text and OCR"
        }
    }
}
