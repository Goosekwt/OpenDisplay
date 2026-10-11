# OpenDisplay

A personal, open-source Windows-to-iPad display project. USB first, Wi-Fi fallback, remembered pairing, and temporary position arrows on both screens. Independent implementation; not affiliated with Duet.

**Development build.** USB desktop playback and position arrows have been confirmed on a physical iPad. The host passes 25 core checks, including automatic sizing and keeping adjacent displays attached through rotation. The installed iPad build previously passed 63 simulator tests. GPU capture is smoother in owner testing, but sustained 60 fps, Wi-Fi, and physical rotation/reopen acceptance are not yet verified. Windows builds remain unsigned; the owner manually disabled Smart App Control for personal development. The app does not change security settings.

## Components

- Native Windows host: .NET 10 / Windows Forms. Creates a local pairing QR, captures a selected display, sends authenticated encrypted H.264, and stays in the tray while waiting for the iPad.
- Native iPad receiver: SwiftUI, Network, CryptoKit and AVFoundation. Source and build instructions live in `ipad/`.
- Real extra monitor: the separately maintained [Virtual Display Driver](https://github.com/VirtualDrivers/Virtual-Display-Driver). OpenDisplay does not use Duet's proprietary driver.
- USB: the Apple Devices service already installed on Windows, accessed via the usbmux protocol. Video itself travels through the cable tunnel. No Wi-Fi is required for the USB transport design.
- Wi-Fi: Bonjour discovery, with an iPad IP address fallback. No account, relay or Internet service is used for video.

## Build the Windows host

Install the .NET 10 SDK and an FFmpeg build containing `libx264`. For fast NVIDIA capture, the build also needs `ddagrab` and `h264_nvenc`; AMD hardware encoding uses `h264_amf`. FFmpeg must be on PATH, or set `FfmpegPath` in `%LOCALAPPDATA%\OpenDisplay\settings.json`.

```powershell
dotnet build windows/OpenDisplay.Host/OpenDisplay.Host.csproj -c Release
dotnet run --project windows/OpenDisplay.Tests/OpenDisplay.Tests.csproj -c Release
dotnet run --project windows/OpenDisplay.Host/OpenDisplay.Host.csproj -c Release
```

## One-time extra-display setup

The app starts with no capture selected when a virtual display is absent. For an actual extended desktop, install the signed open-source driver and select **Extend** in Windows display settings. Preserve the physical screen as your main display. Position the virtual screen beside it; OpenDisplay uses that arrangement for its arrows.

The scoped installer `windows/Install-VirtualDisplay.ps1` downloads release 25.7.23 from the upstream project, verifies its pinned SHA-256 and signed catalog, creates one root display device, and preserves existing driver configuration. It refuses to replace an existing virtual display. Administrator rights are required to install a driver; downloading and checking it does not require them:

```powershell
./windows/Install-VirtualDisplay.ps1 -DownloadOnly
# In an administrator PowerShell, once ready to add the monitor:
./windows/Install-VirtualDisplay.ps1
```

The installer records its exact device ID in `C:\VirtualDisplayDriver\opendisplay-device.txt`. To undo the added monitor, remove that exact device in Device Manager (or `pnputil /remove-device <exact-id>` as administrator). Do not remove Duet or a physical graphics adapter. The script never reboots the PC.

New installations include 26 size/orientation profiles. `-UpdateOwnedModes` adds these without deleting existing modes, checks the installation receipt against the OpenDisplay adapter, saves a backup, and requests the upstream driver's supported reload command. It cannot update an unrelated virtual display. Windows may separately mark an installation as pending reboot; never reboot automatically.

Alternatively use the upstream project's Virtual Driver Control app. Upstream cautions that major GPU/driver updates can interact with VDD; see its current documentation before updating graphics drivers.

Mirror mode is an explicit capture test; it does not create extra desktop space.

## Pair and connect

1. Build/sign/install the iPad app using Xcode. Grant Local Network access and Camera access for QR pairing.
2. In the iPad app, scan the QR shown by the Windows host, or paste its pairing key. The key grants access; keep it private. It is stored in iOS Keychain and protected with Windows DPAPI on the PC.
3. Open the Windows host. It automatically selects the extra display and starts waiting on first launch. Manual choices and troubleshooting controls are under **Advanced options**. If you deliberately stopped it, press **Start connecting** to resume.
4. Plug the iPad into Windows, accept Apple's Trust prompt if asked, and open OpenDisplay on the iPad. The host tries USB first, then remembered/manual Wi-Fi and discovery.
5. Closing the Windows window leaves it in the tray. **Quit** from the tray stops it. Start-at-Windows-sign-in is opt-in.

The iPad must remain foregrounded for display use. Reopening it should restart its receiver. A working Wi-Fi session currently keeps its transport until disconnect/reconnect; seamless mid-session handoff to a newly plugged cable is not claimed.

The iPad reports its video viewport in pixels. The host chooses the closest supported virtual-display shape and size before capture; rotation reconnects with the updated size. It reads physical pixel coordinates independently of Windows scaling and keeps the shared screen edge attached during resizing. Native 2420 × 1668 landscape sizing is verified on the development iPad. Unusual window sizes may use the closest available mode.

The virtual iPad display defaults to 200% Windows scaling for readable Retina-size text and cursor, while keeping native-resolution video. `IpadScalePercent` in settings can override that default; `0` leaves scaling alone. Automatic scaling uses an undocumented Windows display-configuration interface, so it validates the response and skips the adjustment on unsupported systems. It never adjusts a physical/primary display or a cloned display source. Resolution and scaling are separate.

## Windows signing

Free signing routes, their requirements, and the current setup status are documented in [Windows signing](docs/windows-signing.md).

### Code signing policy

The application for free SignPath Foundation signing was submitted on 10 October 2026 and is awaiting review. No acceptance or certificate has been issued; current Windows builds remain unsigned. See the [code signing policy](CODE_SIGNING.md) and [privacy policy](PRIVACY.md).

Smart App Control initially blocked `OpenDisplay.Host.dll` as unsigned (Code Integrity events 3033/3077). The owner subsequently turned that policy off manually, allowing physical USB testing. No trusted Windows code-signing identity is installed; compatibility with Smart App Control remains unverified until provider signing and dependency coverage are resolved.

`windows/Publish.ps1` creates a self-contained development build. When given an existing trusted Windows code-signing certificate thumbprint and the Windows SDK SignTool path, it signs and verifies the executable. It does not change Windows security settings, install trust certificates, or obtain a signing service. A self-signed certificate is not a substitute for a provider trusted by Smart App Control. See [Microsoft's signing guidance](https://learn.microsoft.com/en-us/windows/apps/develop/smart-app-control/code-signing-for-smart-app-control).

## Current limits

- The NVIDIA path captures the selected display on its owning GPU with Desktop Duplication and NVENC. It falls back to GDI capture with probed AMD encoding, then software encoding if necessary. Hardware output is bounded at 3840 × 2880; software output at 1920 × 1440, preserving aspect ratio. Oversized NVIDIA capture uses the compatible path. A silent capture process is restarted instead of leaving an indefinitely frozen connection.
- 30 or 60 fps is a target, not a guarantee. The live counter measures encoded frames, including repeats of unchanged desktop content; it does not measure unique motion frames or iPad presentation rate. Extra FFmpeg frame duplication is disabled. See [capture validation](docs/capture-validation.md) for measured limits.
- No audio, touch-to-mouse, Apple Pencil pressure, HDR, remote Internet desktop, keyboard sharing, or Duet-wide feature parity yet.
- Driver installation and signing/provisioning are separate one-time prerequisites.
- USB playback, native landscape desktop/cursor sizing, and the updated position arrows are owner-confirmed. Wi-Fi playback, cable-only isolation with Wi-Fi disabled, wake/reopen reconnect, and portrait rotation still need physical acceptance checks.

For troubleshooting, `%LOCALAPPDATA%\OpenDisplay\runtime-status.json` holds one replaceable local snapshot of connection status, encoder, frame/byte counters, and measurement time. It contains no pairing key or desktop image and is never uploaded automatically.

## Protocol and dependencies

The independent wire format is documented in `docs/protocol.md`. Tests exercise fragmented streams, writer serialization, record tampering, replay rejection, bounds, and display geometry. The use of a small custom framing protocol is for this personal prototype; it is not a claim of an external security audit.

Our source is MIT licensed. QRCoder is MIT; .NET has its own notices. FFmpeg and the upstream display driver are separately installed dependencies and retain their licenses. No Duet binaries, branding assets or extracted proprietary source are included.

Read-only inspection of the installed Duet package found UMDF 2.33 / IddCx 1.2 display-driver registration, a separate bus enumerator and a WPD USB filter. This supports the architectural choice of a separate display driver and transport, but does **not** establish Duet's private wire protocol or runtime performance.
