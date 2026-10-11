# Privacy

OpenDisplay sends display video and connection messages to the iPad paired by its user, over a USB tunnel or a local network. Local-network discovery advertises the receiver and its service address. The PC and iPad exchange names and display dimensions for connection and sizing.

During an active input-capable session, touches, pointer movement, scrolling, keyboard events and committed text travel from the iPad to the paired PC through the same authenticated, encrypted connection. The host applies them to Windows. Input contents are not recorded in diagnostics or sent to a developer service.

Pairing information is saved locally using Windows DPAPI and iOS Keychain. The pairing QR and key authorize a connection and should be kept private. Forgetting the PC on the iPad removes the remembered pairing key there. Windows remembers the successfully authenticated USB device identifier and last Wi-Fi address to speed up reconnects. Windows app settings are kept in `%LOCALAPPDATA%\OpenDisplay`; remove that folder after quitting to reset the PC's saved settings and pairing information.

OpenDisplay has no advertising, analytics, developer-operated video relay, or user-account service. Display video and pairing keys are not sent to a developer-operated server. Installing prerequisites can contact their download providers; Apple and Windows services operate under their own platform policies.

The Windows host keeps a single replaceable `runtime-status.json` snapshot alongside its settings for local troubleshooting. It records the current status/error and at most 12 recent connection-state changes, selected encoder, encoded-frame and sent-byte counts, read/send timing, chunk and input-event counts, receiver frame/drop counters when supported, process ID, and timestamps. It does not contain pairing keys, keystrokes, typed text or display images and is not uploaded automatically.

The source project and its build/release service on GitHub are public. Do not attach real pairing keys, private device identifiers, or sensitive screen captures to public issues.
