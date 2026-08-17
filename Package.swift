// swift-tools-version: 6.2
import PackageDescription

// The live-device capture SDK (DEVICEKIT.md). Deliberately standalone — it gets
// dropped into somebody else's app, so it depends on nothing but the system.
//
// Two products, because the two ends of the wire need different things:
//
//   StudioDeviceWire — the format itself. iOS AND macOS, pure Codable, no UIKit.
//                      Studio links this, so there is ONE definition of the wire
//                      format rather than two copies drifting apart.
//   StudioDeviceKit  — the SDK proper: capture, Bonjour, control server. iOS
//                      only; every file is `#if os(iOS)` so the package still
//                      builds (to nothing) when Studio pulls in the wire target.
let package = Package(
    name: "StudioDeviceKit",
    platforms: [.iOS(.v17), .macOS(.v15)],
    products: [
        .library(name: "StudioDeviceWire", targets: ["StudioDeviceWire"]),
        .library(name: "StudioDeviceKit", targets: ["StudioDeviceKit"]),
    ],
    targets: [
        .target(name: "StudioDeviceWire", swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(
            name: "StudioDeviceKit",
            dependencies: ["StudioDeviceWire"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "StudioDeviceWireTests",
            dependencies: ["StudioDeviceWire"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
