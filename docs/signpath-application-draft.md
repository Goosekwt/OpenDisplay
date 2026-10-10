# SignPath application status

Submitted on 10 October 2026. The owner authorized public publication under Goosekwt, confirmed GitHub MFA, and approved the provider terms and contact-data processing. The form displayed "Form submitted" and "Thank you, we'll be in touch soon." Provider review is pending. These notes are not a claim of eligibility, acceptance, or sponsorship. Personal application contact details are deliberately omitted from the public repository.

## Project description

OpenDisplay is an independent, MIT-licensed Windows-to-iPad second-screen prototype. The native Windows host captures a virtual display and sends authenticated, encrypted H.264 to a native iPad receiver. USB is preferred, with local Wi-Fi fallback. Pairing is remembered, the host selects a display mode based on the iPad viewport, and temporary arrows show the relative display position.

The app is intended for personal use. It has no account service, advertising, analytics, cloud relay, or remote Internet desktop feature. It does not include Duet code or binaries. A separately installed upstream Virtual Display Driver provides the extra Windows desktop; OpenDisplay does not request signing for that driver's binaries.

## Public project

- Repository: [Goosekwt/OpenDisplay](https://github.com/Goosekwt/OpenDisplay).
- License: MIT.
- Initial version: [0.1.0 unsigned development preview](https://github.com/Goosekwt/OpenDisplay/releases/tag/v0.1.0), with a Windows archive and SHA-256 checksum.
- Release status: Windows build succeeds; all 20 core checks passed on GitHub's Windows runner. The iPad build passed 63 simulator tests, and development build 0.1.0 (3) installed on the owner's iPad. Physical cross-device playback and automatic display resizing still need verification.
- Signing scope: the project's Windows host and core library. The upstream virtual display driver, FFmpeg, .NET runtime and QRCoder are separate components with their own licenses. Packaging and signature coverage must be agreed with SignPath before requesting a signed release. The current QRCoder DLL is unsigned; signing only OpenDisplay's own files has not been proved sufficient for Smart App Control.

## Remaining onboarding

The application includes the public source, release and privacy policy links. It explicitly describes the project as new, with no established download statistics, media coverage or large community, and states that physical cross-device acceptance testing remains pending. No download count, project history, reputation, completed hardware test, or Foundation relationship should be invented.

After acceptance, configure the verified GitHub build, signing policy and credentials using the provider's onboarding instructions. Keep signing credentials in the service's secret store, not the source tree. Require the maintainer's manual release approval.

The Windows workflow is in `.github/workflows/windows.yml`. It builds and tests on GitHub-hosted Windows, uploads an unsigned artifact, and only requests signing through an explicit manual run after all provider variables and credentials are supplied. `docs/signpath-artifact-configuration.xml` is a draft covering the three project binaries, with product/version restrictions. Provider validation and signature coverage for dependencies remain pending.

## Proposed privacy statement

OpenDisplay sends display video and connection messages to the iPad paired by its user, over a USB tunnel or local network. Local-network discovery advertises the receiver and its service address. Pairing information is saved locally using Windows DPAPI and iOS Keychain. OpenDisplay does not send display video or pairing keys to a developer-operated server and has no analytics or advertising integration. Installing prerequisites may contact their download providers; OS services operate under their own platform policies.

Review the privacy statement when release behavior changes. Add the Foundation's required credit and the confirmed role assignments only once the relationship is approved.

Application: https://signpath.org/apply.html

Requirements: https://signpath.org/terms.html

Build integration: https://docs.signpath.io/trusted-build-systems/github
