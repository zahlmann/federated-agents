// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "FederatedAgents",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "FederatedAgentsCore",
            targets: ["FederatedAgentsCore"]
        ),
        .executable(
            name: "FederatedAgentsReceiver",
            targets: ["FederatedAgentsReceiver"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/duckdb/duckdb-swift.git", from: "1.1.3"),
    ],
    targets: [
        .target(
            name: "FederatedAgentsCore",
            dependencies: [
                .product(name: "DuckDB", package: "duckdb-swift"),
            ]
        ),
        .executableTarget(
            name: "FederatedAgentsReceiver",
            dependencies: ["FederatedAgentsCore"],
            resources: [
                .copy("Resources"),
            ]
        ),
        .testTarget(
            name: "FederatedAgentsCoreTests",
            dependencies: ["FederatedAgentsCore"],
            resources: [
                .copy("Fixtures"),
            ]
        ),
    ]
)
