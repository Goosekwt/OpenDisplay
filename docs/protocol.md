# OpenDisplay transport v1

This is the implementation contract, not a claim of device validation.

The iPad listens on TCP port 42150 and advertises `_opendisplay._tcp` via Bonjour while foregrounded. Windows initiates the connection. USB uses Apple's installed usbmux service (127.0.0.1:27015) to reach the SAME iPad TCP listener; Wi-Fi uses its LAN address. All video bytes must pass over the selected transport. USB must work with Wi-Fi disabled.

## Pairing and authentication

Windows generates a cryptographically random 32-byte pairing key. A QR string `opendisplay://pair?v=1&key=<base64url key>&name=<URL-escaped PC name>` transfers this to the iPad. Manual base64url entry is supported. Store it in iOS Keychain / Windows DPAPI, never logs. No unauthenticated video.

Handshake (exact binary lengths):
1. Windows sends ASCII `OPD1` + 32 random bytes C.
2. iPad sends ASCII `OPA1` + 32 random bytes S + HMAC-SHA256(key, UTF8("server") || C || S).
3. Windows verifies in constant time, sends HMAC-SHA256(key, UTF8("client") || C || S).
4. iPad verifies before accepting the session. Close on failure; handshake deadline 5 seconds.

Derive two AES-256 keys with HKDF-SHA256: input key material = pairing key, salt = C || S, info = UTF8("OpenDisplay/v1/client") for Windows-to-iPad and UTF8("OpenDisplay/v1/server") for iPad-to-Windows. Length 32. Independent new random C and S per connection, no key/nonce reuse.

## Records

Each record is uint32 big-endian length L, uint64 big-endian sequence, ciphertext, 16-byte GCM tag. L includes sequence+ciphertext+tag, excludes the length prefix. Plaintext is one byte type followed by payload. Sequence starts at zero independently in each direction and increments strictly. Nonce is 4 zero bytes followed by the 8-byte sequence. AAD is the 8-byte sequence. Reject nonconsecutive sequences, invalid tags and L outside 25..8,388,633 before allocating.

Type 1: UTF8 JSON hello. The iPad sends its hello immediately after authentication: `{"name":"iPad","deviceId":"persistent UUID","ready":true,"displayWidth":2420,"displayHeight":1668}`. Display dimensions are the actual video viewport in pixels in its current orientation, bounded to 320..8192 per axis. The host selects the closest supported virtual-display mode, then replies `{"name":"PC","width":1600,"height":1000,"fps":30,"transport":"USB","ipadEdge":"left"}` with the actual encoded size. Older peers may omit the display dimensions. Transport is `USB` or `Wi-Fi`. Edge is left/right/top/bottom. Rotation or viewport resizing closes the iPad's current session; the reconnect hello supplies the new dimensions so Windows adapts before capture restarts.

Type 2: raw Annex B H.264 stream chunks (NOT necessarily whole NALs or frames). Receiver incrementally parses 3/4-byte start codes across record boundaries, retains SPS/PPS, groups VCL NALs into access units at AUD boundaries, and displays decoded samples immediately. Stream contains AUD NALs and repeats SPS/PPS at IDRs; no B frames. On disconnect, reset the parser and decoder. The final incomplete access unit may be discarded on disconnect.

Type 3: UTF8 JSON identify event: `{"edge":"left","seconds":3}`. Arrow sits at that edge and points outward toward the other display. Honor Reduce Motion. Windows shows the corresponding arrow on the neighboring physical display.

Type 4: heartbeat opaque bytes echoed by iPad. Windows sends every 2 seconds. Missing reply for 8 seconds ends the session and triggers retry. Single serialized writer per direction.

Type 5 reserved; no remote input in v1. Type 6: UTF8 JSON error with `message`; never include credentials.

## Lifecycle

At most one authenticated session on the iPad. A new authenticated connection replaces the old one (an unauthenticated connection must NOT interrupt it). Returning to foreground restarts the listener and advertisement; backgrounding closes the session and stops capture on Windows. Reconnect retries use bounded backoff. Windows prefers USB, tries remembered/manual Wi-Fi and Bonjour as fallback. A stalled video send cancels the stream rather than accumulating an unbounded queue. The host stays running in the tray; start-at-login is opt-in.

The first release does not claim audio, Apple Pencil pressure, remote touch, HDR, USB transport failover without interruption, or Duet-equivalent latency. These require separate work and measurement.
