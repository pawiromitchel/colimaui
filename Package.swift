// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ColimaBar",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ColimaKit", targets: ["ColimaKit"]),
        .executable(name: "ColimaBar", targets: ["ColimaBar"]),
    ],
    targets: [
        .target(name: "ColimaKit"),
        .executableTarget(name: "ColimaBar", dependencies: ["ColimaKit"]),
        .testTarget(name: "ColimaKitTests", dependencies: ["ColimaKit"]),
    ]
)
