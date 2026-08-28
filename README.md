# SpringMotionDeviceKit

Capture a real iOS device's screen **and its multi-touch input** for Promo
Studio. Debug builds only.

The simulator can't do this — no real multi-touch, and its video and the host's
input log run on separate clocks. Here one process owns both, so a pinch is
recordable and the log lands on the video frame-exactly.

## Install

```swift
// Package.swift
.package(url: "https://github.com/djfumberger/SpringMotionDeviceKit", from: "0.1.0")
// target dependency:
.product(name: "SpringMotionDeviceKit", package: "SpringMotionDeviceKit")
```

```swift
// SwiftUI
WindowGroup { ContentView().springMotionCapture() }

// UIKit
func application(_: UIApplication,
                 didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    SpringMotion.enable()
    return true
}
```

Add to the **host app's** `Info.plist` — the SDK cannot add these for you, and
without them iOS blocks the connection with no error:

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>Connects to Spring Motion on your Mac to record demo footage.</string>
<key>NSBonjourServices</key>
<array><string>_springmotion._tcp</string></array>
```

`SpringMotion.enable()` prints a specific warning at launch if either is
missing, and `hello` reports them to Studio so the device doesn't just silently
fail to appear.

Every implementation file is wrapped in
`#if os(iOS) && (DEBUG || STUDIO_DEVICE_CAPTURE)`, so release builds carry no
screen recorder, no listener and no `sendEvent` swizzle. `SpringMotion` and
`SpringMotionHUD` keep their signatures as stubs, so your call sites compile in
every configuration without `#if` of your own.

Confirm it on your own release build:

```sh
strings YourApp.app/YourApp | grep -c springMotionDeviceKit_sendEvent   # → 0
otool -L YourApp.app/YourApp | grep -ci replaykit                 # → 0
```

(Xcode 26 puts *Debug* code in `YourApp.debug.dylib` rather than the app binary,
so check the dylib if you want to confirm the SDK is present in Debug.)

## Recording without a Mac

Networking is phase 2. Until then — and afterwards, for takes shot away from the
desk — drive it directly:

```swift
SpringMotion.enable()
SpringMotionHUD.show()      // floating, draggable record button
```

Or in code:

```swift
try await SpringMotion.startRecording()
let take = try await SpringMotion.stopRecording()
// take.videoURL, take.touchesURL, take.maximumConcurrentStrokes
```

The HUD's **Share Take** hands both files to a share sheet — AirDrop them to the
Mac and inspect them by hand. `SpringMotion.pendingTakes` lists anything not yet
collected.

## Phase 0: what to verify on real hardware

The capture core is written against four assumptions. Shoot one take with the
HUD and check each — question 2 is the one that could still change the
architecture.

1. **Do ReplayKit's PTS share the host clock with `CACurrentMediaTime()`?**
   The take records both anchors on purpose. In `touches.json`, compare
   `video.firstFramePTS` against `video.firstFrameArrival`: they should be
   within a frame or so of each other. A large constant gap means the clocks
   differ and the Mac should rebase against `firstFrameArrival` instead — a
   one-line change, applicable to takes already shot.

2. **Does in-app capture include the system keyboard's pixels?** Type something
   during the take and look at the video. Touches on the keyboard *are* logged
   (the tap hooks `UIWindow` at the class level, which catches
   `UIRemoteKeyboardWindow`), but if the keys don't render, keyboard-heavy demos
   need the Broadcast Extension path instead.

3. **Do concurrent touch identities survive?** Pinch, and check
   `maximumConcurrentStrokes == 2` in the HUD readout. Then a three-finger
   swipe. Each finger should be one stroke with a continuous sample run, not
   several fragments.

4. **What actually arrives?** Check `screen.pixelWidth/Height` against the
   device's real resolution, and eyeball the frame rate on a fast scroll.

## Layout

| file | what it owns |
|---|---|
| `SpringMotionDeviceWire/TouchTake.swift` | the wire format — strokes, samples, anchors |
| `SpringMotionDeviceWire/Framing.swift` | length-prefixed messages + blob bodies |
| `SpringMotionDeviceWire/Protocol.swift` | request/response envelopes, TXT keys |
| `SpringMotionDeviceKit/TouchTap.swift` | the `UIWindow.sendEvent` hook |
| `SpringMotionDeviceKit/ScreenCapture.swift` | ReplayKit → `AVAssetWriter` |
| `SpringMotionDeviceKit/TakeRecorder.swift` | one take: start both, stop both, assemble |
| `SpringMotionDeviceKit/TakeStore.swift` | takes on disk awaiting collection |
| `SpringMotionDeviceKit/SpringMotion.swift` | the public surface |
| `SpringMotionDeviceKit/SpringMotionHUD.swift` | the no-Mac record button |

Studio links `SpringMotionDeviceWire` only, so the format has one definition rather
than two copies drifting apart.
