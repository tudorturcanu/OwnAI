import CoreImage
import Foundation
import UIKit
import Vision

enum ImageAnalysisContextBuilder {
    nonisolated static func context(for image: UIImage, mode: ImageProcessingMode) async -> String? {
        guard let cgImage = preparedCGImage(from: image, mode: mode) else { return nil }

        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = true
        textRequest.automaticallyDetectsLanguage = true

        let classifyRequest = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        try? handler.perform([textRequest, classifyRequest])

        var parts: [String] = []
        if let recognizedText = recognizedText(from: textRequest, maxCharacters: mode.maxRecognizedTextCharacters) {
            parts.append("Visible text:\n\(recognizedText)")
        }

        if let imageLabels = imageLabels(from: classifyRequest, limit: mode == .highQuality ? 10 : 6) {
            parts.append("Likely visual content: \(imageLabels)")
        }

        let width = Int(image.size.width * image.scale)
        let height = Int(image.size.height * image.scale)
        parts.append("Image size: \(width)x\(height)px")

        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "\n\n")
    }

    nonisolated private static func recognizedText(
        from request: VNRecognizeTextRequest,
        maxCharacters: Int
    ) -> String? {
        guard let observations = request.results, !observations.isEmpty else { return nil }

        let lines = observations
            .sorted {
                let lhsBox = $0.boundingBox
                let rhsBox = $1.boundingBox
                if abs(lhsBox.midY - rhsBox.midY) > 0.03 {
                    return lhsBox.midY > rhsBox.midY
                }
                return lhsBox.midX < rhsBox.midX
            }
            .compactMap { $0.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return nil }
        let text = lines.joined(separator: "\n")
        guard text.count > maxCharacters else { return text }
        return String(text.prefix(maxCharacters)).trimmingCharacters(in: .whitespacesAndNewlines)
            + "\n[Visible text clipped.]"
    }

    nonisolated private static func imageLabels(
        from request: VNClassifyImageRequest,
        limit: Int
    ) -> String? {
        guard let classifications = request.results else { return nil }
        let labels = classifications
            .filter { $0.confidence >= 0.3 }
            .prefix(limit)
            .map { "\($0.identifier) (\(Int($0.confidence * 100))%)" }

        guard !labels.isEmpty else { return nil }
        return labels.joined(separator: ", ")
    }

    nonisolated private static func preparedCGImage(from image: UIImage, mode: ImageProcessingMode) -> CGImage? {
        let resized = downsample(image, maxDimension: mode.analysisMaxDimension) ?? image
        let cgImage = resized === image ? normalizedCGImage(from: resized) : resized.cgImage

        guard mode == .highQuality else {
            return cgImage
        }

        guard let validCGImage = cgImage else { return nil }
        let source = CIImage(cgImage: validCGImage)
        let cleaned = source
            .clampedToExtent()
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0.15,
                kCIInputContrastKey: 1.16,
                kCIInputBrightnessKey: 0.01
            ])
            .applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: 0.28
            ])
            .cropped(to: source.extent)

        return CIContext(options: [.useSoftwareRenderer: false])
            .createCGImage(cleaned, from: cleaned.extent)
    }

    nonisolated private static func downsample(_ image: UIImage, maxDimension: CGFloat) -> UIImage? {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        let longestEdge = max(pixelWidth, pixelHeight)
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
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    nonisolated private static func normalizedCGImage(from image: UIImage) -> CGImage? {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        return rendered.cgImage
    }
}
