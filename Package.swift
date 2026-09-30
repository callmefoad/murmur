// swift-tools-version:6.2
import PackageDescription
import Foundation

let liteBuild = ProcessInfo.processInfo.environment["MURMUR_LITE"] == "1"
let packageDependencies: [Package.Dependency] = [
    // Sparkle is kept in the Apple-only build too: the updater is part of
    // Murmur's shipped app, not part of the optional Whisper engine.
    .package(
        url: "https://github.com/sparkle-project/Sparkle.git",
        exact: "2.9.6"),
    // Runs the punctuation model (see Punctuator.swift). Static library, so
    // nothing extra to embed or sign in the app bundle.
    .package(
        url: "https://github.com/microsoft/onnxruntime-swift-package-manager",
        exact: "1.24.2"),
] + (liteBuild ? [] : [
    .package(
        url: "https://github.com/argmaxinc/WhisperKit.git",
        .upToNextMinor(from: "1.0.0")),
    // Parakeet engine (see ParakeetEngine.swift).
    .package(
        url: "https://github.com/FluidInference/FluidAudio.git",
        exact: "0.17.4"),
])
let murmurDependencies: [Target.Dependency] = [
    .product(name: "Sparkle", package: "Sparkle"),
    "PunctuationRuntime",
] + (liteBuild ? [] : [
    .product(name: "WhisperKit", package: "WhisperKit"),
    .product(name: "FluidAudio", package: "FluidAudio"),
])

let package = Package(
    name: "Murmur",
    platforms: [.macOS(.v26)],
    dependencies: packageDependencies,
    targets: [
        // C wrapper over ONNX Runtime for the punctuation model. The
        // Objective-C bindings can't read the model's bool outputs.
        .target(
            name: "PunctuationRuntime",
            dependencies: [
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
            ],
            path: "Sources/PunctuationRuntime"
        ),
        .executableTarget(
            name: "Murmur",
            dependencies: murmurDependencies,
            path: "Sources/Murmur",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MurmurTests",
            dependencies: ["Murmur"],
            path: "Tests/MurmurTests"
        )
    ]
)
