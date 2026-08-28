#if os(iOS) && !(DEBUG || STUDIO_DEVICE_CAPTURE)
import SwiftUI

/// Release stub — same surface, no window, no recorder.
@MainActor
public enum SpringMotionHUD {
    public static func show() {}
    public static func hide() {}
}
#endif

#if os(iOS) && (DEBUG || STUDIO_DEVICE_CAPTURE)
import SpringMotionDeviceWire
import SwiftUI
import UIKit

/// A floating record button, for driving a take with no Mac in the loop.
///
/// This exists to make the capture core testable before the transport does —
/// shoot a take, share the two files out, and check the touch log against the
/// video by hand. It stays useful afterwards: a take shot on a train still lands
/// in Studio when the developer gets back.
///
/// Deliberately a separate opt-in from `enable()`. Floating chrome over an app
/// you are recording is exactly the thing you don't want in the frame — it hides
/// itself while recording, but the choice to have it at all is the host's.
@MainActor
public enum SpringMotionHUD {
    private static var window: UIWindow?

    /// Show the floating control. Call after `SpringMotion.enable()`.
    public static func show() {
        guard SpringMotion.isEnabled, window == nil else { return }
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
        else { return }

        let hud = PassthroughWindow(windowScene: scene)
        // Above the app, below system alerts. The HUD must never be what the
        // user's tap lands on by accident.
        hud.windowLevel = .alert - 1
        hud.backgroundColor = .clear
        hud.rootViewController = HostingController(rootView: HUDView())
        hud.rootViewController?.view.backgroundColor = .clear
        hud.isHidden = false
        window = hud
    }

    public static func hide() {
        window?.isHidden = true
        window = nil
    }

    /// A window that only claims the pixels its controls actually occupy —
    /// everything else falls through to the app being recorded.
    private final class PassthroughWindow: UIWindow {
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            guard let hit = super.hitTest(point, with: event) else { return nil }
            return hit === rootViewController?.view ? nil : hit
        }
    }

    private final class HostingController<Content: View>: UIHostingController<Content> {
        override var prefersStatusBarHidden: Bool { false }
    }
}

private struct HUDView: View {
    @State private var isRecording = false
    @State private var lastTake: SpringMotion.TakeHandle?
    @State private var error: String?
    @State private var isBusy = false
    /// Dragged out of the way — the button must never be stuck over the part of
    /// the app the demo is about.
    @State private var offset = CGSize.zero
    @State private var dragStart = CGSize.zero

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Spacer()
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.red.opacity(0.9), in: .rect(cornerRadius: 8))
                    .frame(maxWidth: 240, alignment: .trailing)
            }
            if let lastTake, !isRecording {
                takeSummary(lastTake)
            }
            recordButton
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .offset(offset)
        .gesture(
            DragGesture()
                .onChanged { offset = CGSize(width: dragStart.width + $0.translation.width,
                                             height: dragStart.height + $0.translation.height) }
                .onEnded { _ in dragStart = offset }
        )
        // While recording the control fades almost away: it is in shot, and a
        // bright red button in the corner of every frame is not what anyone is
        // trying to film.
        .opacity(isRecording ? 0.35 : 1)
    }

    private var recordButton: some View {
        Button {
            Task { await toggle() }
        } label: {
            ZStack {
                Circle()
                    .fill(.black.opacity(0.55))
                    .frame(width: 56, height: 56)
                RoundedRectangle(cornerRadius: isRecording ? 4 : 12)
                    .fill(.red)
                    .frame(width: isRecording ? 20 : 26,
                           height: isRecording ? 20 : 26)
            }
            .overlay(Circle().stroke(.white.opacity(0.35), lineWidth: 1)
                .frame(width: 56, height: 56))
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .accessibilityLabel(isRecording ? "Stop Studio recording" : "Start Studio recording")
    }

    private func takeSummary(_ take: SpringMotion.TakeHandle) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(String(format: "%.1fs · %d strokes", take.duration, take.strokeCount))
            // The number that says whether multi-touch capture actually worked.
            Text("\(take.maximumConcurrentStrokes) finger\(take.maximumConcurrentStrokes == 1 ? "" : "s") at peak")
                .foregroundStyle(.secondary)
            Button("Share Take") { share(take) }
                .font(.caption.bold())
                .padding(.top, 2)
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.white)
        .padding(10)
        .background(.black.opacity(0.6), in: .rect(cornerRadius: 10))
    }

    private func toggle() async {
        isBusy = true
        defer { isBusy = false }
        error = nil
        do {
            if isRecording {
                lastTake = try await SpringMotion.stopRecording()
                isRecording = false
            } else {
                lastTake = nil
                _ = try await SpringMotion.startRecording()
                isRecording = true
            }
        } catch let failure as SpringMotionResponse.Failure {
            error = failure.message
            isRecording = false
        } catch {
            self.error = error.localizedDescription
            isRecording = false
        }
    }

    private func share(_ take: SpringMotion.TakeHandle) {
        let items: [Any] = [take.videoURL, take.touchesURL]
        let sheet = UIActivityViewController(activityItems: items,
                                             applicationActivities: nil)
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first,
              let presenter = scene.windows.first(where: { $0.isKeyWindow })?
            .rootViewController
        else { return }
        // iPad requires a popover anchor or this traps.
        sheet.popoverPresentationController?.sourceView = presenter.view
        sheet.popoverPresentationController?.sourceRect = CGRect(
            x: presenter.view.bounds.midX, y: presenter.view.bounds.maxY - 40,
            width: 1, height: 1)
        presenter.present(sheet, animated: true)
    }
}
#endif
