// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "conjet",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "conjet", targets: ["ConjetCLI"]),
        .executable(name: "conjetd", targets: ["ConjetDaemon"]),
        .executable(name: "ConjetApp", targets: ["ConjetApp"]),
        .library(name: "ConjetAppCore", targets: ["ConjetAppCore"]),
        .library(name: "ConjetCore", targets: ["ConjetCore"]),
        .library(name: "ConjetPower", targets: ["ConjetPower"]),
        .library(name: "ConjetVZ", targets: ["ConjetVZ"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.78.0")
    ],
    targets: [
        .target(
            name: "ConjetCore",
            linkerSettings: [
                .linkedFramework("CoreServices", .when(platforms: [.macOS]))
            ]
        ),
        .target(name: "ConjetPower", dependencies: ["ConjetCore"]),
        .target(
            name: "ConjetVZ",
            dependencies: [
                "ConjetCore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio")
            ],
            linkerSettings: [
                .linkedFramework("Virtualization", .when(platforms: [.macOS]))
            ]
        ),
        .executableTarget(
            name: "ConjetCLI",
            dependencies: ["ConjetCore", "ConjetPower", "ConjetVZ"]
        ),
        .executableTarget(
            name: "ConjetDaemon",
            dependencies: ["ConjetCore", "ConjetPower", "ConjetVZ"]
        ),
        .target(
            name: "ConjetAppCore",
            dependencies: ["ConjetCore"]
        ),
        .executableTarget(
            name: "ConjetApp",
            dependencies: ["ConjetAppCore", "ConjetCore"],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(name: "ConjetCoreTests", dependencies: ["ConjetCore"]),
        .testTarget(name: "ConjetPowerTests", dependencies: ["ConjetPower"]),
        .testTarget(name: "ConjetVZTests", dependencies: ["ConjetVZ"]),
        .testTarget(name: "ConjetAppCoreTests", dependencies: ["ConjetAppCore"])
    ]
)
