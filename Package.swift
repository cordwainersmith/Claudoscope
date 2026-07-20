// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Claudoscope",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
    ],
    targets: [
        .executableTarget(
            name: "Claudoscope",
            dependencies: [
                .product(name: "OrderedCollections", package: "swift-collections"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "MCP", package: "swift-sdk"),
            ],
            path: "Claudoscope",
            exclude: ["Info.plist", "Claudoscope.entitlements"],
            resources: [
                .copy("Resources/HardeningBaseline"),
                .process("Resources/app-icon-rounded.png"),
                .process("Resources/app-icon.png"),
                .process("Resources/AppIcon.icns"),
                .process("Resources/claude-avatar.png"),
                .process("Resources/logo-c-t.png"),
                .process("Resources/menu-bar-icon.png"),
            ]
        ),
        .executableTarget(
            name: "claudoscope-mcp",
            path: "McpShim"
        ),
        .testTarget(
            name: "ClaudoscopeTests",
            dependencies: [
                "Claudoscope",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "ClaudoscopeTests"
        ),
    ]
)
