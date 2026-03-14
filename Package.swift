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
            exclude: ["Info.plist"],
            resources: [
                .process("Resources"),
            ]
        ),
    ]
)
