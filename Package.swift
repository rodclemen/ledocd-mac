// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LEDOCD",
    platforms: [
        .macOS(.v12)
    ],
    targets: [
        .executableTarget(
            name: "LEDOCD",
            path: "Sources/LEDOCD"
        )
    ]
)
