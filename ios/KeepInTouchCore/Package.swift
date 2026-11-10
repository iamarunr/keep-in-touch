// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KeepInTouchCore",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [.library(name: "KeepInTouchCore", targets: ["KeepInTouchCore"])],
    targets: [
        .target(name: "KeepInTouchCore"),
        .testTarget(name: "KeepInTouchCoreTests", dependencies: ["KeepInTouchCore"]),
    ]
)
