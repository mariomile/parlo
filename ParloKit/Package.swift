// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ParloKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ParloCore", targets: ["ParloCore"]),
        .library(name: "ParloEngines", targets: ["ParloEngines"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7"),
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.1"),
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", exact: "0.1.6"),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", exact: "0.13.0"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", exact: "1.3.5"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.32.3"),
    ],
    targets: [
        .target(name: "ParloCore"),
        .target(
            name: "ParloEngines",
            dependencies: [
                "ParloCore",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            ]
        ),
        .testTarget(name: "ParloCoreTests", dependencies: ["ParloCore"]),
        .testTarget(name: "ParloEnginesTests", dependencies: ["ParloEngines"]),
    ]
)
