// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JTSMacCompanion",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "JTSMacCompanion", targets: ["JTSMacCompanion"])],
    dependencies: [.package(path: "../Packages/RemoteDesktopCore"), .package(path: "../Packages/JTSCompanionTransport")],
    targets: [
        .executableTarget(name: "JTSMacCompanion", dependencies: ["RemoteDesktopCore", .product(name: "JTSCompanionTransport", package: "JTSCompanionTransport"), .product(name: "JTSRelayEnrollment", package: "JTSCompanionTransport")]),
        .testTarget(name: "JTSMacCompanionTests", dependencies: ["JTSMacCompanion", "RemoteDesktopCore"])
    ],
    swiftLanguageModes: [.v5]
)
