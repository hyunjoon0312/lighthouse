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
        .target(
            name: "LighthouseCore",
            resources: [.copy("Resources")]
        ),
        .executableTarget(name: "Lighthouse", dependencies: ["LighthouseCore"]),
        .testTarget(name: "LighthouseCoreTests", dependencies: ["LighthouseCore"]),
        .testTarget(name: "LighthouseTests", dependencies: ["Lighthouse", "LighthouseCore"]),
    ],
    swiftLanguageModes: [.v6]
)
