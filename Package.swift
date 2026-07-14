// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ProjectSync",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ProjectSync", targets: ["ProjectSync"])
    ],
    targets: [
        .executableTarget(
            name: "ProjectSync",
            path: "Sources/ProjectSync"
        ),
        .testTarget(
            name: "ProjectSyncTests",
            dependencies: ["ProjectSync"]
        )
    ],
    swiftLanguageModes: [.v5]
)
