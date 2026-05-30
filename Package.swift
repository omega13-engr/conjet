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
        .library(name: "ConjetCore", targets: ["ConjetCore"]),
        .library(name: "ConjetBench", targets: ["ConjetBench"]),
        .library(name: "ConjetPower", targets: ["ConjetPower"]),
        .library(name: "ConjetVZ", targets: ["ConjetVZ"])
    ],
    targets: [
        .target(
            name: "ConjetCore",
            linkerSettings: [
                .linkedFramework("CoreServices", .when(platforms: [.macOS]))
            ]
        ),
        .target(name: "ConjetBench", dependencies: ["ConjetCore"]),
        .target(name: "ConjetPower", dependencies: ["ConjetCore"]),
        .target(
            name: "ConjetVZ",
            dependencies: ["ConjetCore"],
            linkerSettings: [
                .linkedFramework("Virtualization", .when(platforms: [.macOS]))
            ]
        ),
        .executableTarget(
            name: "ConjetCLI",
            dependencies: ["ConjetCore", "ConjetBench", "ConjetPower", "ConjetVZ"]
        ),
        .executableTarget(
            name: "ConjetDaemon",
            dependencies: ["ConjetCore", "ConjetPower", "ConjetVZ"]
        ),
        .testTarget(name: "ConjetCoreTests", dependencies: ["ConjetCore"]),
        .testTarget(name: "ConjetBenchTests", dependencies: ["ConjetBench"]),
        .testTarget(name: "ConjetPowerTests", dependencies: ["ConjetPower"]),
        .testTarget(name: "ConjetVZTests", dependencies: ["ConjetVZ"])
    ]
)
