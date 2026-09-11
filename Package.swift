// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ProjectSweep",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CleanupCore", targets: ["CleanupCore"]),
        .executable(name: "ProjectSweep", targets: ["ProjectSweepApp"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "CleanupCore", dependencies: ["CSQLite"], resources: [.process("Resources")]),
        .executableTarget(name: "ProjectSweepApp", dependencies: ["CleanupCore"], resources: [.process("Resources/ToolLogos")]),
        .testTarget(name: "CleanupCoreTests", dependencies: ["CleanupCore", "CSQLite"])
    ],
    swiftLanguageModes: [.v6]
)
