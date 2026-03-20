// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "LocalAIKit",
    platforms: [
        .iOS(.v18)
    ],
    products: [
        .library(
            name: "LocalAIKit",
            type: .static,
            targets: ["LocalAIKit"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/mattt/AnyLanguageModel",
            from: "0.6.0",
            traits: ["MLX"]
        ),
        .package(path: "../KokoroSwiftLocal")
    ],
    targets: [
        .target(
            name: "LocalAIKit",
            dependencies: [
                .product(name: "AnyLanguageModel", package: "AnyLanguageModel"),
                .product(name: "KokoroSwift", package: "KokoroSwiftLocal")
            ],
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("MetalPerformanceShaders"),
                .linkedFramework("MetalPerformanceShadersGraph")
            ]
        )
    ]
)
