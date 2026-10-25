// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DockPin",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DockPinCore", targets: ["DockPinCore"]),
        .executable(name: "dockpin-probe", targets: ["dockpin-probe"]),
    ],
    targets: [
        .target(name: "DockPinCore"),
        .executableTarget(name: "dockpin-probe", dependencies: ["DockPinCore"]),
        .testTarget(name: "DockPinCoreTests", dependencies: ["DockPinCore"]),
    ]
)
