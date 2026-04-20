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
    dependencies: [],
    targets: [
        .target(
            name: "LocalAIKit",
            dependencies: [],
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("MetalPerformanceShaders"),
                .linkedFramework("MetalPerformanceShadersGraph")
            ]
        )
    ]
)
