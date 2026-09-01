// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Present",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Present", path: "Sources")
    ]
)
