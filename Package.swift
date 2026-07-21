// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GoodCloudKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "GoodCloudKit", targets: ["GoodCloudKit"]),
        .executable(name: "GoodCloudExample", targets: ["GoodCloudExample"]),
        .executable(name: "gck-probe", targets: ["GCKProbe"]),
    ],
    targets: [
        .target(name: "GoodCloudKit"),
        .executableTarget(name: "GoodCloudExample", dependencies: ["GoodCloudKit"]),
        .executableTarget(name: "GCKProbe", dependencies: ["GoodCloudKit"]),
        .testTarget(name: "GoodCloudKitTests", dependencies: ["GoodCloudKit"]),
    ]
)
