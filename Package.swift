// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ProjectSync",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ProjectSync", targets: ["ProjectSync"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4")
    ],
    targets: [
        .executableTarget(
            name: "ProjectSync",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/ProjectSync"
        ),
        .testTarget(
            name: "ProjectSyncTests",
            dependencies: ["ProjectSync"]
        )
    ],
    swiftLanguageModes: [.v5]
)
