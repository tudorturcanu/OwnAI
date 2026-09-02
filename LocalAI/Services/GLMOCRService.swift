import CoreImage
import Foundation
import UIKit

#if !targetEnvironment(simulator)
import MLX
import MLXLMCommon
import MLXVLM
#endif

enum GLMOCRError: LocalizedError {
    case unsupportedDevice
    case modelNotDownloaded
    case appNotActive
    case invalidImage
    case emptyOutput

    var errorDescription: String? {
        switch self {
        case .unsupportedDevice:
            return "Enhanced OCR requires an A14/M1-class GPU or newer."
        case .modelNotDownloaded:
            return "Download GLM OCR from Models before enabling Enhanced OCR."
        case .appNotActive:
            return "Enhanced OCR can only run while the app is active."
        case .invalidImage:
            return "The document page could not be prepared for Enhanced OCR."
        case .emptyOutput:
            return "Enhanced OCR did not recognize text on this page."
        }
    }
}

/// Runs the specialized GLM-OCR checkpoint as a short-lived auxiliary model.
/// It deliberately releases the active chat model first: holding two MLX
/// checkpoints at once is enough to trigger jetsam on otherwise-supported
/// phones. ChatView reconstructs conversational continuity from persisted
/// history when the selected chat model is loaded again.
@MainActor
final class GLMOCRService {
    static let shared = GLMOCRService()
    static let modelID = ModelInfo.glmOCR_4bit.id

    private init() {}

    var isModelReady: Bool {
        MLXStorage.validationReport(for: Self.modelID).isValid
    }

    func recognizeText(in images: [UIImage]) async throws -> [String] {
        guard !images.isEmpty else { return [] }

        #if targetEnvironment(simulator)
        throw GLMOCRError.unsupportedDevice
        #else
        guard DeviceResourcePolicy.supportsMLXCompute else {
            throw GLMOCRError.unsupportedDevice
        }
        guard UIApplication.shared.applicationState == .active else {
            throw GLMOCRError.appNotActive
        }
        guard isModelReady else {
            throw GLMOCRError.modelNotDownloaded
        }

        LLMEngine.shared?.unloadModel()
        MLX.GPU.clearCache()
        defer { MLX.GPU.clearCache() }

        let modelPath = MLXStorage.modelDirectory(for: Self.modelID)
        MLXStorage.normalizeConfigIfNeeded(in: modelPath)
        let container = try await VLMModelFactory.shared.loadContainer(
            from: modelPath,
            using: LocalAITokenizerLoader()
        )

        var results: [String] = []
        results.reserveCapacity(images.count)

        for image in images {
            try Task.checkCancellation()
            guard let ciImage = CIImage(image: preparedImage(image)) else {
                throw GLMOCRError.invalidImage
            }

            let session = ChatSession(
                container,
                generateParameters: GenerateParameters(
                    maxTokens: 4_096,
                    maxKVSize: 4_096,
                    kvBits: 4,
                    temperature: 0,
                    topP: 1,
                    prefillStepSize: 128
                )
            )

            var rawText = ""
            for try await chunk in session.streamResponse(
                to: "Text Recognition:",
                image: .ciImage(ciImage)
            ) {
                try Task.checkCancellation()
                rawText += chunk
            }

            let text = AssistantOutputSanitizer.sanitize(rawText)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw GLMOCRError.emptyOutput }
            results.append(text)
        }

        return results
        #endif
    }

    private func preparedImage(_ image: UIImage) -> UIImage {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        let longestEdge = max(pixelWidth, pixelHeight)
        let maxDimension: CGFloat = 1_800
        guard longestEdge > maxDimension else { return image }

        let scale = maxDimension / longestEdge
        let targetSize = CGSize(
            width: max(1, floor(pixelWidth * scale)),
            height: max(1, floor(pixelHeight * scale))
        )
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            UIColor.white.setFill()
            UIRectFill(CGRect(origin: .zero, size: targetSize))
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }
}
