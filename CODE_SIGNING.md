# Code signing policy

OpenDisplay is preparing an application to the SignPath Foundation's free open-source signing program. It has not been accepted and its current Windows development release is unsigned. Do not treat the prepared workflow as evidence of an existing certificate or completed signing.

The project maintainer, reviewer and proposed release-signing approver is [Goosekwt](https://github.com/Goosekwt). Changes from outside contributors require maintainer review. Release-signing requests require explicit maintainer approval, with multi-factor authentication on both GitHub and SignPath accounts.

The Windows workflow builds on GitHub-hosted runners and publishes the build artifact before any signing request. Signing is an optional manual workflow step, limited to the main branch, and requires provider configuration that is not yet available. The proposed artifact configuration signs only OpenDisplay's own executable and libraries and constrains their product and version metadata. Upstream dependencies must retain their own provenance.

If the project is accepted, the release pages will add the required attribution: “Free code signing provided by SignPath.io, certificate by SignPath Foundation”. That attribution describes the intended future arrangement, not the current release.

See the [privacy policy](PRIVACY.md), [setup status](docs/windows-signing.md) and [Foundation terms](https://signpath.org/terms.html). No Windows security configuration changes are made by this project.
