// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SonosKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SonosKit", targets: ["SonosKit"]),
    ],
    targets: [
        .target(name: "SonosKit"),
        .testTarget(name: "SonosKitTests", dependencies: ["SonosKit"]),
    ]
)
