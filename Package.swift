// swift-tools-version:6.2
import PackageDescription
import Foundation

let liteBuild = ProcessInfo.processInfo.environment["MURMUR_LITE"] == "1"
let packageDependencies: [Package.Dependency] = liteBuild ? [] : [
    .package(
        url: "https://github.com/argmaxinc/WhisperKit.git",
        .upToNextMinor(from: "1.0.0")),
]
let murmurDependencies: [Target.Dependency] = liteBuild ? [] : [
    .product(name: "WhisperKit", package: "WhisperKit"),
]

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
