# iPad app

Native SwiftUI receiver for iPadOS 17 or later. Open `OpenDisplay.xcodeproj` in Xcode, select your own development team and a unique bundle ID, then run on your iPad. The checked-in project is generated from `project.yml`; XcodeGen is only needed when regenerating it.

The app listens while foregrounded, advertises Bonjour, stores the pairing key in Keychain, and decodes the host's authenticated H.264 stream. It reports the video viewport in pixels and reconnects after an orientation or window-size change. The PC chooses the corresponding desktop mode. The iPad controls do not ask for a resolution. The picture fills the screen edge to edge (aspect fit), and the on-screen keyboard never changes the size sent to the PC.

When the PC's hello includes `"inputVersion":1`, the app forwards input as type 5 records: tap to click, drag to hold the left button, touch and hold to right-click, two fingers to scroll, plus Magic Keyboard keys (with repeat) and trackpad hover, click, right-click, drag and scroll. The iPad pointer hides over the picture, because the PC's capture already draws the Windows cursor, and appears again over the controls. The keyboard button in the connection controls brings up the on-screen keyboard. A small button at the top edge shows the connection controls. Older PCs without that field keep the view-only behavior, where tapping anywhere shows the controls. With `"receiverStatsVersion":1`, heartbeat replies carry `{"enqueuedFrames":N,"droppedFrames":M}`, which counts frames accepted for display, not frames actually shown on screen.

For an unsigned compile check:

```sh
xcodebuild -project OpenDisplay.xcodeproj -scheme OpenDisplay \
  -configuration Release -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```

Run `OpenDisplayTests` on an available iPad simulator from Xcode. Tests cover protocol vectors, H.264 fragmentation and decoding, session authentication, heartbeat and receiver stats, session replacement, resize reconnect, arrow geometry, and input encoding, mapping, queueing and gestures. A simulator pass does not prove physical USB/Wi-Fi playback or latency.

The personal IPA in `../dist/ipad` is signed for the owner's registered devices. It is not a generally installable release and should not be published with the open-source archive. Its embedded provisioning profile expires; rebuild with valid provisioning when necessary.
