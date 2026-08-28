// swift-tools-version: 6.2
import PackageDescription

// The live-device capture SDK (DEVICEKIT.md). Deliberately standalone — it gets
// dropped into somebody else's app, so it depends on nothing but the system.
//
// Two products, because the two ends of the wire need different things:
//
//   SpringMotionDeviceWire — the format itself. iOS AND macOS, pure Codable, no UIKit.
//                      Studio links this, so there is ONE definition of the wire
//                      format rather than two copies drifting apart.
//   SpringMotionDeviceKit  — the SDK proper: capture, Bonjour, control server. iOS
//                      only; every file is `#if os(iOS)` so the package still
//                      builds (to nothing) when Studio pulls in the wire target.
let package = Package(
    name: "SpringMotionDeviceKit",
    platforms: [.iOS(.v17), .macOS(.v15)],
    products: [
        .library(name: "SpringMotionDeviceWire", targets: ["SpringMotionDeviceWire"]),
        .library(name: "SpringMotionDeviceKit", targets: ["SpringMotionDeviceKit"]),
    ],
    targets: [
        .target(name: "SpringMotionDeviceWire", swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(
            name: "SpringMotionDeviceKit",
            dependencies: ["SpringMotionDeviceWire"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SpringMotionDeviceWireTests",
            dependencies: ["SpringMotionDeviceWire"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
