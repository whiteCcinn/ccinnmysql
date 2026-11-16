// swift-tools-version: 6.0
import PackageDescription

let settings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "CcinnMysql",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MySQLWire", targets: ["MySQLWire"]),
        .library(name: "MySQLKit", targets: ["MySQLKit"]),
        .library(name: "CcinnMysqlKit", targets: ["CcinnMysqlKit"]),
        .executable(name: "CcinnMysql", targets: ["CcinnMysql"]),
    ],
    targets: [
        // MySQL client/server protocol: framing, handshake, TLS request, auth plugins, text results. No I/O.
        .target(name: "MySQLWire", swiftSettings: settings),
        // Transport (TLS upgrade), connections, pool, sessions, flavor-aware metadata and operations.
        .target(name: "MySQLKit", dependencies: ["MySQLWire"], swiftSettings: settings),
        // UI-independent app logic: profiles, SQL tooling, completion, charts, export, EXPLAIN, row edit, MCP.
        .target(name: "CcinnMysqlKit", dependencies: ["MySQLKit"], swiftSettings: settings),
        // SwiftUI/AppKit application (also hosts the `mcp` subcommand).
        .executableTarget(name: "CcinnMysql", dependencies: ["MySQLKit", "CcinnMysqlKit"], swiftSettings: settings),

        .testTarget(name: "MySQLWireTests", dependencies: ["MySQLWire"], swiftSettings: settings),
        .testTarget(name: "MySQLKitTests", dependencies: ["MySQLWire", "MySQLKit"], swiftSettings: settings),
        .testTarget(name: "CcinnMysqlKitTests", dependencies: ["MySQLKit", "CcinnMysqlKit"], resources: [.copy("Fixtures")],
                    swiftSettings: settings),
        .testTarget(name: "IntegrationTests", dependencies: ["MySQLWire", "MySQLKit", "CcinnMysqlKit"], swiftSettings: settings),
        // AppKit behaviour of the app's views (editor text storage, input methods).
        .testTarget(name: "CcinnMysqlAppTests", dependencies: ["CcinnMysql", "CcinnMysqlKit"], swiftSettings: settings),
    ],
    swiftLanguageModes: [.v6]
)
