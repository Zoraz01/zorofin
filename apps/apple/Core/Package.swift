// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ZorofinCore",
    platforms: [.macOS(.v14), .iOS(.v18), .tvOS(.v18)],
    products: [.library(name: "ZorofinCore", targets: ["ZorofinCore"])],
    targets: [
        .target(name: "ZorofinCore"),
        .testTarget(name: "ZorofinCoreTests", dependencies: ["ZorofinCore"], resources: [.copy("Fixtures")])
    ]
)
