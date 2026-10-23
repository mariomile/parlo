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
    ],
    targets: [
        .target(name: "ParloCore"),
        .target(
            name: "ParloEngines",
            dependencies: [
                "ParloCore",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ]
        ),
        .testTarget(name: "ParloCoreTests", dependencies: ["ParloCore"]),
        .testTarget(name: "ParloEnginesTests", dependencies: ["ParloEngines"]),
    ]
)
