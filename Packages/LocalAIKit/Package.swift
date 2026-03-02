// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "LocalAIKit",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "LocalAIKit",
            targets: ["LocalAIKit"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/mattt/AnyLanguageModel",
            from: "0.6.0",
            traits: ["MLX"]
        )
    ],
    targets: [
        .target(
            name: "LocalAIKit",
            dependencies: [
                .product(name: "AnyLanguageModel", package: "AnyLanguageModel")
            ],
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("MetalPerformanceShaders"),
                .linkedFramework("MetalPerformanceShadersGraph")
            ]
        )
    ]
)
