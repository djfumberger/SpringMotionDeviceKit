#if os(iOS) && (DEBUG || STUDIO_DEVICE_CAPTURE)
import SpringMotionDeviceWire
import UIKit

/// Who and what this device is — the TXT record's contents, and the metadata
/// Studio matches against its device-frame catalog.
@MainActor
enum DeviceInfo {
    /// The hardware identifier, `iPhone17,1`. Deliberately NOT translated to a
    /// marketing name here: Studio owns that table, so it can learn new devices
    /// without every host app shipping a new SDK build.
    static var machine: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    static var identity: TouchTake.DeviceIdentity {
        let bundle = Bundle.main
        return TouchTake.DeviceIdentity(
            name: UIDevice.current.name,
            machine: machine,
            systemVersion: UIDevice.current.systemVersion,
            appBundleID: bundle.bundleIdentifier ?? "",
            appVersion: (bundle.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "")
    }

    /// The active scene's screen, in its CURRENT orientation — ReplayKit's
    /// frames are interface-oriented too, so the log and the video agree.
    static var activeScreen: UIScreen? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?.screen
            ?? UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.screen }.first
    }

    static var screen: TouchTake.Screen {
        guard let screen = activeScreen else { return TouchTake.Screen() }
        let bounds = screen.coordinateSpace.bounds
        return TouchTake.Screen(
            width: Float(bounds.width),
            height: Float(bounds.height),
            scale: Float(screen.scale),
            pixelWidth: Int(bounds.width * screen.scale),
            pixelHeight: Int(bounds.height * screen.scale),
            orientation: orientationName)
    }

    static var orientationName: String {
        let orientation = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.interfaceOrientation }.first
        switch orientation {
        case .portrait: return "portrait"
        case .portraitUpsideDown: return "portraitUpsideDown"
        case .landscapeLeft: return "landscapeLeft"
        case .landscapeRight: return "landscapeRight"
        default: return "portrait"
        }
    }

    /// Host-app configuration the SDK cannot fix for the developer. Reported
    /// through `hello` so a missing plist key shows up as a specific
    /// instruction in Studio instead of a device that just never appears.
    static var configurationWarnings: [String] {
        var warnings: [String] = []
        let info = Bundle.main.infoDictionary ?? [:]
        if info["NSLocalNetworkUsageDescription"] == nil {
            warnings.append("Add NSLocalNetworkUsageDescription to Info.plist — "
                            + "without it iOS blocks the connection silently.")
        }
        let services = info["NSBonjourServices"] as? [String] ?? []
        if !services.contains(SpringMotionProtocol.serviceType) {
            warnings.append("Add \(SpringMotionProtocol.serviceType) to NSBonjourServices "
                            + "in Info.plist — without it the device cannot advertise.")
        }
        return warnings
    }
}
#endif
