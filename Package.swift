// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Lighthouse",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LighthouseCore", targets: ["LighthouseCore"]),
        .executable(name: "Lighthouse", targets: ["Lighthouse"]),
    ],
    targets: [
        .target(name: "LighthouseCore"),
        .executableTarget(name: "Lighthouse", dependencies: ["LighthouseCore"]),
        .testTarget(name: "LighthouseCoreTests", dependencies: ["LighthouseCore"]),
    ],
    swiftLanguageModes: [.v5]
)
