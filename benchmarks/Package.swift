// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "conjet-benchmarks",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "conjet-bench", targets: ["ConjetBenchCLI"]),
        .library(name: "ConjetBench", targets: ["ConjetBench"])
    ],
    dependencies: [
        .package(path: "..")
    ],
    targets: [
        .target(
            name: "ConjetBench",
            dependencies: [
                .product(name: "ConjetCore", package: "conjet")
            ]
        ),
        .executableTarget(
            name: "ConjetBenchCLI",
            dependencies: [
                "ConjetBench",
                .product(name: "ConjetCore", package: "conjet")
            ]
        ),
        .testTarget(
            name: "ConjetBenchTests",
            dependencies: [
                "ConjetBench",
                .product(name: "ConjetCore", package: "conjet")
            ]
        )
    ]
)
