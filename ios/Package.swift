// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "EdgeAssistantCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "EdgeAssistantCore", targets: ["EdgeAssistantCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMinor(from: "3.32.3")),
        .package(url: "https://github.com/huggingface/swift-huggingface", .upToNextMajor(from: "0.9.0")),
        .package(url: "https://github.com/huggingface/swift-transformers", .upToNextMajor(from: "1.3.0")),
    ],
    targets: [
        .target(
            name: "EdgeAssistantCore",
            dependencies: [
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        ),
        .testTarget(name: "EdgeAssistantCoreTests", dependencies: ["EdgeAssistantCore"]),
    ],
    swiftLanguageModes: [.v5]
)
