// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "QuietComfortCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "QuietComfortCore", targets: ["QuietComfortCore"])],
    targets: [
        .target(name: "QuietComfortCore"),
        .testTarget(name: "QuietComfortCoreTests", dependencies: ["QuietComfortCore"])
    ]
)

