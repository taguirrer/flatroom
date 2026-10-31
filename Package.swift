// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Flatroom",
    platforms: [.macOS("14.2")],
    products: [
        .library(name: "AudioEngine", targets: ["AudioEngine"]),
        .executable(name: "TapTest", targets: ["TapTest"]),
        .executable(name: "Flatroom", targets: ["Flatroom"]),
    ],
    targets: [
        .target(name: "AudioEngine"),
        .executableTarget(name: "TapTest", dependencies: ["AudioEngine"]),
        .executableTarget(name: "ConvolverCheck", dependencies: ["AudioEngine"]),
        .executableTarget(name: "Flatroom", dependencies: ["AudioEngine"]),
    ]
)
