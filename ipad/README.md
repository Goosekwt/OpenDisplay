# iPad app

Native SwiftUI receiver for iPadOS 17 or later. Open `OpenDisplay.xcodeproj` in Xcode, select your own development team and a unique bundle ID, then run on your iPad. The checked-in project is generated from `project.yml`; XcodeGen is only needed when regenerating it.

The app listens while foregrounded, advertises Bonjour, stores the pairing key in Keychain, and decodes the host's authenticated H.264 stream. It reports the video viewport in pixels and reconnects after an orientation or window-size change. The PC chooses the corresponding desktop mode. The iPad controls do not ask for a resolution.

For an unsigned compile check:

```sh
xcodebuild -project OpenDisplay.xcodeproj -scheme OpenDisplay \
  -configuration Release -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```

Run `OpenDisplayTests` on an available iPad simulator from Xcode. Tests cover protocol vectors, H.264 fragmentation and decoding, session authentication, heartbeat, session replacement, resize reconnect, and arrow geometry. A simulator pass does not prove physical USB/Wi-Fi playback or latency.

The personal IPA in `../dist/ipad` is signed for the owner's registered devices. It is not a generally installable release and should not be published with the open-source archive. Its embedded provisioning profile expires; rebuild with valid provisioning when necessary.
