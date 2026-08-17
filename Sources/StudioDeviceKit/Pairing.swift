#if os(iOS) && (DEBUG || STUDIO_DEVICE_CAPTURE)
import Foundation
import StudioDeviceWire
import SwiftUI
import UIKit

/// Who is allowed to drive this device.
///
/// The MCP server Studio already runs is unauthenticated, which is fine because
/// it binds loopback. This listens on the LAN, where "unauthenticated" means
/// anyone on the café Wi-Fi can start a screen recording of your app and read
/// it back. So: an unknown peer gets a six-digit code displayed on the device,
/// and has to read it across to be trusted.
///
/// Trust is per-token and persists, so pairing is a once-per-Mac ceremony
/// rather than a once-per-take one.
@MainActor
final class PairingStore {
    private static let defaultsKey = "com.fumberger.studiodevicekit.trustedTokens"
    static let codeLength = 6
    /// A six-digit code is a million possibilities, which a LAN attacker can
    /// walk through quickly given unlimited tries. Five, then the code is burnt
    /// and the user has to deliberately start again.
    private static let maximumAttempts = 5

    private var tokens: Set<String>
    private var pending: PendingCode?

    private struct PendingCode {
        var code: String
        var expires: TimeInterval
        var attempts: Int
    }

    init() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? []
        tokens = Set(stored)
    }

    func isTrusted(_ token: String?) -> Bool {
        guard let token, !token.isEmpty else { return false }
        return tokens.contains(token)
    }

    /// Show a fresh code and start the window in which it can be redeemed.
    /// Replaces any code already on screen — a second Mac asking to pair
    /// invalidates the first one's code rather than queueing behind it.
    func beginPairing() {
        let code = (0..<Self.codeLength)
            .map { _ in String(Int.random(in: 0...9)) }
            .joined()
        pending = PendingCode(code: code,
                              expires: Date().timeIntervalSince1970
                                  + StudioDeviceProtocol.pairingCodeLifetime,
                              attempts: 0)
        PairingCodeWindow.show(code: code)
    }

    /// Redeem a code for a lasting token, or say precisely why not.
    func redeem(_ code: String) throws -> String {
        guard var pending else {
            throw StudioDeviceResponse.Failure(
                .badPairingCode, "No pairing code is showing on the device.")
        }
        guard Date().timeIntervalSince1970 < pending.expires else {
            self.pending = nil
            PairingCodeWindow.hide()
            throw StudioDeviceResponse.Failure(
                .badPairingCode, "That pairing code expired — try connecting again.")
        }

        pending.attempts += 1
        let normalized = code.filter(\.isNumber)
        guard normalized == pending.code else {
            if pending.attempts >= Self.maximumAttempts {
                self.pending = nil
                PairingCodeWindow.hide()
                throw StudioDeviceResponse.Failure(
                    .badPairingCode,
                    "Too many incorrect codes — connect again for a new one.")
            }
            self.pending = pending
            let left = Self.maximumAttempts - pending.attempts
            throw StudioDeviceResponse.Failure(
                .badPairingCode,
                "Incorrect code — \(left) attempt\(left == 1 ? "" : "s") left.")
        }

        self.pending = nil
        PairingCodeWindow.hide()
        let token = UUID().uuidString
        tokens.insert(token)
        UserDefaults.standard.set(Array(tokens), forKey: Self.defaultsKey)
        return token
    }

    func cancelPairing() {
        pending = nil
        PairingCodeWindow.hide()
    }

    /// Forget every paired Mac — offered through `StudioDevice.unpairAll()`
    /// for when a device changes hands.
    func revokeAll() {
        tokens.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        cancelPairing()
    }
}

/// The code, full-screen, unmissable. It only exists between a connection
/// attempt and its redemption, so it can afford to be loud.
@MainActor
enum PairingCodeWindow {
    private static var window: UIWindow?

    static func show(code: String) {
        hide()
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
        else { return }
        let host = UIWindow(windowScene: scene)
        host.windowLevel = .alert
        host.backgroundColor = .clear
        host.rootViewController = UIHostingController(rootView: PairingCodeView(code: code))
        host.rootViewController?.view.backgroundColor = .clear
        host.isHidden = false
        window = host
    }

    static func hide() {
        window?.isHidden = true
        window = nil
    }
}

private struct PairingCodeView: View {
    let code: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.75).ignoresSafeArea()
            VStack(spacing: 16) {
                Text("Pair with Promo Studio")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.8))
                Text(spaced)
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                Text("Enter this code on your Mac")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(32)
            .background(.ultraThinMaterial, in: .rect(cornerRadius: 24))
        }
    }

    /// Grouped three and three — a run of six digits is read wrong often
    /// enough to matter when the penalty is a burnt attempt.
    private var spaced: String {
        guard code.count == 6 else { return code }
        let mid = code.index(code.startIndex, offsetBy: 3)
        return "\(code[..<mid]) \(code[mid...])"
    }
}
#endif
