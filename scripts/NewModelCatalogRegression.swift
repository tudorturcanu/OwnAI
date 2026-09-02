import Foundation

@main
enum NewModelCatalogRegression {
    private static let expectedModels: [(symbol: String, id: String, size: String, isVision: Bool)] = [
        ("qwen3VL_2b_4bit", "mlx-community/Qwen3-VL-2B-Instruct-4bit", "1.79", true),
        ("qwen3VL_4b_4bit", "mlx-community/Qwen3-VL-4B-Instruct-4bit", "3.11", true),
        ("lfm25_vl_3b_4bit", "LiquidAI/LFM2.5-VL-3B-MLX-4bit", "2.38", true),
        ("glmOCR_4bit", "mlx-community/GLM-OCR-4bit", "1.25", true),
        ("qwen38_27b_4bit", "mlx-community/Qwen3.8-27B-4bit", "16.08", true),
        ("devstralSmall2_24b_4bit", "mlx-community/mistralai_Devstral-Small-2-24B-Instruct-2512-MLX-4Bit", "15.14", true),
        ("nemotron35_lightning_30b_a3b_4bit", "mlx-community/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-4bit", "17.79", false),
    ]

    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let modelInfo = try source(root, "LocalAI/Models/ModelInfo.swift")
        let documentManager = try source(root, "LocalAI/Services/DocumentManager.swift")
        let settings = try source(root, "LocalAI/Views/AdvancedSettingsView.swift")
        let releasedCatalog = try slice(
            modelInfo,
            from: "static let releasedModels: [ModelInfo] = [",
            through: "    ]\n\n    /// Definitions retained"
        )

        for model in expectedModels {
            require(modelInfo.contains("static let \(model.symbol) = ModelInfo("), "missing model definition: \(model.symbol)")
            require(modelInfo.contains("id: \"\(model.id)\""), "wrong or missing model ID: \(model.id)")
            require(modelInfo.contains("sizeGB: \(model.size)"), "wrong model size: \(model.symbol)")
            require(releasedCatalog.contains(".\(model.symbol)"), "model not present in released catalog: \(model.symbol)")
            if model.isVision {
                require(modelInfo.components(separatedBy: "\"\(model.id)\"").count >= 3, "vision model missing from VLM dispatch set: \(model.id)")
            }
        }

        require(modelInfo.contains("sizeGB: 44.86"), "Qwen3 Coder Next size regression")
        require(modelInfo.contains("var isMacOnly: Bool"), "Mac-only model gate is missing")
        require(modelInfo.contains("var requiresImageInput: Bool"), "OCR image-input guard is missing")
        require(documentManager.contains("extractContentUsingGLMOCR"), "enhanced OCR extraction is not wired")
        require(documentManager.contains("fallbackExtraction"), "enhanced OCR fallback is missing")
        require(settings.contains("DocumentOCRBackend.storageKey"), "OCR settings selector is not wired")
        requireUniqueMatches(in: modelInfo, pattern: #"id:\s*\"([^\"]+)\""#, label: "model ID")
        requireUniqueMatches(in: releasedCatalog, pattern: #"(?m)^\s*\.([A-Za-z][A-Za-z0-9_]*)"#, label: "released model")

        print("New model catalog and enhanced OCR regression passed")
    }

    private static func source(_ root: URL, _ relativePath: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private static func slice(_ source: String, from start: String, through end: String) throws -> String {
        guard let startRange = source.range(of: start),
              let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return String(source[startRange.lowerBound..<endRange.upperBound])
    }

    private static func requireUniqueMatches(in source: String, pattern: String, label: String) {
        let expression = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(source.startIndex..., in: source)
        let values = expression.matches(in: source, range: range).compactMap { match -> String? in
            guard let matchRange = Range(match.range(at: 1), in: source) else { return nil }
            return String(source[matchRange])
        }
        let duplicates = Dictionary(grouping: values, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
        require(duplicates.isEmpty, "duplicate \(label)s: \(duplicates.joined(separator: ", "))")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }
}
