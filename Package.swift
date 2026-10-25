// swift-tools-version: 5.9
import PackageDescription

// The protocol and presentation core deliberately has no dependencies.
let package = Package(
    name: "MuxCore",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [.library(name: "MuxCore", targets: ["MuxCore"])],
    targets: [
        .target(name: "MuxCore"),
        .testTarget(name: "MuxCoreTests", dependencies: ["MuxCore"])
    ]
)
