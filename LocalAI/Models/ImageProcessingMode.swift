import Foundation
import CoreGraphics

enum ImageProcessingMode: String, CaseIterable, Identifiable, Sendable {
    case fast
    case highQuality

    nonisolated static let storageKey = "imageProcessingMode"

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
            return String(localized: "Optimize image analysis for quick responses and lower memory use.")
        case .highQuality:
            return String(localized: "Use sharper image input and richer text extraction for screenshots and documents.")
        }
    }

    nonisolated var visionMaxDimension: CGFloat {
        switch self {
        case .fast:
            return 384
        case .highQuality:
            return 768
        }
    }

    nonisolated var analysisMaxDimension: CGFloat {
        switch self {
        case .fast:
            return 800
        case .highQuality:
            return 1200
        }
    }

    nonisolated var maxRecognizedTextCharacters: Int {
        switch self {
        case .fast:
            return 4_000
        case .highQuality:
            return 12_000
        }
    }

    nonisolated static var current: ImageProcessingMode {
        if DeviceResourcePolicy.current.isLowMemoryPhone {
            return .fast
        }
        return ImageProcessingMode(
            rawValue: UserDefaults.standard.string(forKey: storageKey) ?? ImageProcessingMode.fast.rawValue
        ) ?? .fast
    }
}
