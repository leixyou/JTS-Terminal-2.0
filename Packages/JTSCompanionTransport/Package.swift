// swift-tools-version: 5.9
import PackageDescription
import Foundation

// Reuse this checkout's audited OpenSSL archive, never a sibling relay repository or host installation.
let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
let cryptoVendor = repository.appendingPathComponent("Vendor/FreeRDP/JTFreeRDP.xcframework/macos-arm64_x86_64")

let package = Package(
    name: "JTSCompanionTransport",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "JTSCompanionTransport", targets: ["JTSCompanionTransport"]),
        .library(name: "JTSCompanionIPC", targets: ["JTSCompanionIPC"]),
        .library(name: "JTSCompanionClient", targets: ["JTSCompanionClient"]),
        .library(name: "JTSCompanionDevices", targets: ["JTSCompanionDevices"]),
        .library(name: "JTSRelayEnrollment", targets: ["JTSRelayEnrollment"]),
        .library(name: "JTSCompanionServiceRuntime", targets: ["JTSCompanionServiceRuntime"])
    ],
    targets: [
        .target(name: "CPinnedTLS", publicHeadersPath: "include",
                cSettings: [.unsafeFlags(["-I", cryptoVendor.appendingPathComponent("Headers").path])],
                linkerSettings: [.unsafeFlags([cryptoVendor.appendingPathComponent("libJTFreeRDP-universal.a").path])]),
        .target(name: "JTSCompanionIPC"),
        .target(name: "JTSCompanionClient", dependencies: ["JTSCompanionIPC"]),
        .target(name: "JTSRelayEnrollment", dependencies: ["JTSCompanionIPC"]),
        .target(name: "JTSCompanionDevices", dependencies: ["JTSCompanionIPC", "JTSRelayEnrollment"]),
        .target(name: "JTSCompanionTransport", dependencies: ["CPinnedTLS", "JTSCompanionIPC"]),
        .target(name: "JTSCompanionServiceRuntime", dependencies: ["JTSCompanionTransport", "JTSCompanionIPC"]),
        .testTarget(name: "JTSCompanionIPCTests", dependencies: ["JTSCompanionIPC"]),
        .testTarget(name: "JTSCompanionClientTests", dependencies: ["JTSCompanionClient", "JTSCompanionIPC"]),
        .testTarget(name: "JTSCompanionDevicesTests", dependencies: ["JTSCompanionDevices"], resources: [.copy("Fixtures")]),
        .testTarget(name: "JTSRelayEnrollmentTests", dependencies: ["JTSRelayEnrollment"], resources: [.copy("Fixtures")]),
        .testTarget(name: "JTSCompanionServiceRuntimeTests", dependencies: ["JTSCompanionServiceRuntime", "JTSCompanionIPC"]),
        .testTarget(name: "JTSCompanionTransportTests", dependencies: ["JTSCompanionTransport", "JTSCompanionClient", "JTSRelayEnrollment"],
                    resources: [.copy("Fixtures")])
    ]
)
