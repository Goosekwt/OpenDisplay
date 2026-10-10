# Privacy

OpenDisplay sends display video and connection messages to the iPad paired by its user, over a USB tunnel or a local network. Local-network discovery advertises the receiver and its service address. The PC and iPad exchange names and display dimensions for connection and sizing.

Pairing information is saved locally using Windows DPAPI and iOS Keychain. The pairing QR and key authorize a connection and should be kept private. Forgetting the PC on the iPad removes the remembered pairing key there. Windows app settings are kept in `%LOCALAPPDATA%\OpenDisplay`; remove that folder after quitting to reset the PC's saved settings and pairing information.

OpenDisplay has no advertising, analytics, developer-operated video relay, or user-account service. Display video and pairing keys are not sent to a developer-operated server. Installing prerequisites can contact their download providers; Apple and Windows services operate under their own platform policies.

The source project and its build/release service on GitHub are public. Do not attach real pairing keys, private device identifiers, or sensitive screen captures to public issues.
