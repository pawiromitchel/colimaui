// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ColimaUI",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ColimaKit", targets: ["ColimaKit"]),
        .executable(name: "ColimaUI", targets: ["ColimaUI"]),
    ],
    targets: [
        .target(name: "ColimaKit"),
        .executableTarget(name: "ColimaUI", dependencies: ["ColimaKit"]),
        .testTarget(name: "ColimaKitTests", dependencies: ["ColimaKit"]),
    ]
)
