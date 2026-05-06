// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Claudoscope",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "Claudoscope",
            dependencies: [
                .product(name: "OrderedCollections", package: "swift-collections"),
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
        .testTarget(
            name: "ClaudoscopeTests",
            dependencies: ["Claudoscope"],
            path: "ClaudoscopeTests"
        ),
    ]
)
