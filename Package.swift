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
] + (liteBuild ? [] : [
    .package(
        url: "https://github.com/argmaxinc/WhisperKit.git",
        .upToNextMinor(from: "1.0.0")),
])
let murmurDependencies: [Target.Dependency] = [
    .product(name: "Sparkle", package: "Sparkle"),
] + (liteBuild ? [] : [
    .product(name: "WhisperKit", package: "WhisperKit"),
])

let package = Package(
    name: "Murmur",
    platforms: [.macOS(.v26)],
    dependencies: packageDependencies,
    targets: [
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
