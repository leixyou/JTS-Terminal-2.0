// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RemoteDesktopCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "RemoteDesktopCore", targets: ["RemoteDesktopCore"])],
    targets: [
        .target(name: "RemoteDesktopCore"),
        .testTarget(name: "RemoteDesktopCoreTests", dependencies: ["RemoteDesktopCore"])
    ]
)
