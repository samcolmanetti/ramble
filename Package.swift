// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ramble",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "RambleCore", targets: ["RambleCore"]),
        .executable(name: "ramble-sniff", targets: ["ramble-sniff"]),
        .executable(name: "ramble-check", targets: ["ramble-check"]),
    ],
    targets: [
        .target(name: "RambleCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "ramble-sniff", dependencies: ["RambleCore"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        // The test suite is an executable, not a testTarget: XCTest and
        // swift-testing both ship with Xcode, which this machine does not have.
        .executableTarget(name: "ramble-check", dependencies: ["RambleCore"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
