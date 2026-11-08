// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AVPPlay",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AVPPlayCore", targets: ["AVPPlayCore"]),
        .executable(name: "avpplay", targets: ["avpplay"]),
        .executable(name: "AVPPlayApp", targets: ["AVPPlayApp"]),
    ],
    targets: [
        .target(name: "AVPPlayCore", resources: [.process("Resources")]),
        .executableTarget(name: "avpplay", dependencies: ["AVPPlayCore"]),
        .executableTarget(name: "AVPPlayApp", dependencies: ["AVPPlayCore"]),
        .testTarget(name: "AVPPlayCoreTests", dependencies: ["AVPPlayCore"], exclude: ["Fixtures169"]),
        .testTarget(name: "AVPPlayAppTests", dependencies: ["AVPPlayApp", "AVPPlayCore"], resources: [.copy("Fixtures/recipes")]),
    ]
)
