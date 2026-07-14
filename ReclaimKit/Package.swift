// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ReclaimKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ReclaimKit", targets: ["ReclaimKit"]),
        .executable(name: "reclaim-scan", targets: ["reclaim-scan"]),
    ],
    targets: [
        .target(name: "ReclaimKit"),
        .executableTarget(name: "reclaim-scan", dependencies: ["ReclaimKit"]),
        .testTarget(name: "ReclaimKitTests", dependencies: ["ReclaimKit"]),
    ]
)
