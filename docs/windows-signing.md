# Windows signing status

OpenDisplay's Windows host is currently unsigned. Smart App Control blocked the development DLL on the owner's PC. The display driver has its own upstream signature; that does not sign the OpenDisplay host. Apple development signing is separate and is already configured for the iPad build.

The owner subsequently disabled Smart App Control manually for personal development and confirmed USB playback. OpenDisplay and its setup scripts do not change Windows security settings. No signing service has been purchased. The owner selected free SignPath signing and authorized public publication at [Goosekwt/OpenDisplay](https://github.com/Goosekwt/OpenDisplay). Source and an unsigned Windows preview are public. The SignPath application was submitted on 10 October 2026; the form confirmed receipt and provider review is pending.

## Free options

### SignPath Foundation

[SignPath Foundation](https://signpath.org/) provides free signing for accepted open-source projects. This is an application, not an immediate certificate download. A new project is not guaranteed acceptance.

The project must be public, maintained, released, documented, and use an eligible open-source license. Signing requires a verifiable build, named maintainers and approvers, multi-factor authentication, and manual release approval. The certificate belongs to the Foundation. Its terms limit signing to the project's own code; upstream dependencies require separate consideration. See the [Foundation terms](https://signpath.org/terms.html).

OpenDisplay has MIT-licensed source, build instructions, protocol documentation, an uninstall procedure and a public release built on GitHub's Windows runner. The owner confirmed GitHub MFA and approved the application terms. Do not claim Foundation sponsorship or add its signing credit as an existing relationship before acceptance.

The [GitHub integration](https://docs.signpath.io/trusted-build-systems/github) can build on GitHub-hosted Windows runners, upload an unsigned artifact, and submit that artifact for approval. Its organization ID, project, policy, and API credentials only become available through onboarding. Signing configuration must cover OpenDisplay's executable and loaded libraries; merely signing an installer is insufficient.

The current unsigned release inventory also lists `QRCoder.dll` as unsigned. The draft signing configuration covers only OpenDisplay's own three binaries. Dependency signature coverage must be resolved during onboarding and verified on the target PC before claiming Smart App Control compatibility.

### Microsoft Store

[Individual developer registration](https://learn.microsoft.com/en-us/windows/apps/publish/whats-new-individual-developer) is free through the new onboarding flow and requires identity verification. Microsoft [signs MSIX/AppX packages after Store certification](https://learn.microsoft.com/en-us/windows/apps/publish/get-started); it does not sign an arbitrary EXE or MSI uploaded to the Store.

This would require additional packaging and certification work for OpenDisplay. The separately installed display driver and FFmpeg dependency must be assessed before choosing this distribution route. Store acceptance and timing are not established.

### Personal development without Smart App Control

Windows exposes an option to turn Smart App Control off. This changes app protection across the PC, because there is no per-app exception. Antivirus protection is separate. This project does not change the setting automatically. See [Microsoft's FAQ](https://support.microsoft.com/en-us/windows/security/threat-malware-protection/smart-app-control-frequently-asked-questions).

## Existing build helper

`windows/Publish.ps1` builds a self-contained Windows executable and optionally signs it with an existing certificate accessible to Windows SignTool. It neither obtains a certificate nor configures a cloud signing provider. Its signing branch has not been exercised because no Windows signing identity is installed. A provider-specific integration and a complete loaded-component signature check remain necessary before declaring compatibility with Smart App Control.

Self-signed certificates and Developer Mode are not a general exemption from Smart App Control. A signature also does not establish that USB playback, Wi-Fi playback, sizing, or reconnect behavior has passed physical-device testing.

Sources checked on 10 October 2026. Provider policies can change.
