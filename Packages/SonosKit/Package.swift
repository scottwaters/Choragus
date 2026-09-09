// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SonosKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SonosKit", targets: ["SonosKit"]),
    ],
    targets: [
        .target(name: "SonosKit", resources: [.process("Resources")]),
        .testTarget(name: "SonosKitTests", dependencies: ["SonosKit"]),
    ]
)
