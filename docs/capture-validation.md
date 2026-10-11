# Capture validation — 11 October 2026

## Verified

- Physical USB playback and position-arrow activation confirmed by the owner. The owner describes GPU capture as smoother.
- Independent physical-pixel geometry: the laptop remains 2880 × 1800, and the iPad virtual display is 2420 × 1668. The user's left-side arrangement is preserved.
- Scaling adjustment read back successfully: only the virtual display changed from 125% to 200%; the physical display remained at 200%. On 11 October, the owner confirmed that the final desktop/cursor size and position arrows look good on the physical setup.
- DXGI maps the virtual display to the NVIDIA GPU, independently of the AMD GPU driving the laptop. Native capture uses that exact adapter/output pair.
- Direct capture produced roughly 46–48 encoded frames/second in short isolated tests without FFmpeg frame duplication. A live USB sample measured about 33–35 encoded frames/second at native resolution. Neither is a claim of 60 unique frames/second or iPad presentation rate.
- A later post-acceptance sample at native resolution averaged 33.2 encoded frames/second over 40 seconds of connected USB playback. Individual two-second intervals varied from about 18 to 38 fps, mostly 33–35 fps. An earlier brief 60-fps status reading was not sustained. The connection then closed and the host returned to discovery; whether the receiver was closed/backgrounded was not established. Disconnected intervals are excluded from this average.
- The new Windows circular arrow completed its three-second native compositor check with 189 successful updates, no presentation errors, and disposed its window. Four directional artwork previews were inspected, and the owner accepted the updated arrow experience on 11 October.
- Windows publish and 25 core checks pass. Tests cover encrypted streams, rejection of malformed/replayed records, display mode selection, edge direction, and keeping left/top/right/bottom layouts attached through resizing.
- Claude Code transferred a synthetic 2420 × 1668, 60-fps NVENC fixture to the owner's Mac mini and ran the receiver's parser, assembler, sample builder, pipeline, and VideoToolbox decoder against it. All 120 pictures parsed and decoded at the correct dimensions with zero decode errors and no pipeline drops. Fragmented chunks produced identical access units. This validates the stream format on that Mac; it is not a physical iPad frame-rate measurement.

## Input and motion investigation

- Windows 0.1.3 passes 37 core checks; iPad build 6 passes 99 simulator tests, including full streaming layout checks in both orientations with safe-area and keyboard changes. The physical USB connection reports received input events and receiver frame counters with zero reported pipeline drops in the observed session. These counters do not prove every gesture or key behaves correctly.
- A full-screen calibration fixture at 2420 × 1668 was captured on the physical iPad. All four colored edge strips were present in the device screenshot. This verifies that the transmitted rectangle is complete in full-screen landscape; screenshots do not prove visibility behind the display's rounded physical corners. After rejecting an inset that added black borders, the owner accepted build 6: borders gone and one cursor. The final build has no extra video padding and retains native resolution.
- Windows taskbar settings were inspected: auto-hide and showing the taskbar on all displays were enabled. No taskbar settings were changed.
- A deterministic moving bar captured for 12 seconds produced 706 encoded pictures and 679 distinct bar positions, approximately 56.6 motion updates per second. Alternatives using Windows Graphics Capture, additional pacing, or process priority did not establish a repeatable improvement; the production capture arguments remain unchanged. Artificially producing more duplicate frames was not adopted.
- A synthetic native-resolution NVENC workload encoded 600 frames at about 234 fps. During one live USB sample, encoded-output reads took about 333 seconds cumulatively while network sends took about 3.9 seconds. The observed transport was not the main source of waiting. These are bounded measurements, not guaranteed throughput or end-to-end latency.

## Disconnect and window-return checks

- Windows 0.1.3 scopes automatic removal to the exact installer receipt and adapter path, checks that a physical primary remains, and rejects cloned sources. Receipt parsing covers the installer's optional restart suffix and rejects partial or unrelated IDs.
- A native detach/reattach check left only the 2880 × 1800 primary active, retained the inactive adapter's identity and saved placement, then restored 2420 × 1668 at the original left-side position. The physical display's size and scaling stayed unchanged.
- Native normal and maximized test windows were moved to the primary before detaching. The normal window retained its 900 × 700 size and the maximized window remained maximized on the primary; neither was minimized. Moving windows before removal avoids Windows' asynchronous minimize-on-disconnect policy.
- The installed host starts with only the primary display active while it waits for the iPad. USB unplug/replug acceptance with the owner's regular windows is pending. Default behavior after an established USB session is to wait for USB, matching the owner's preference to disconnect rather than immediately fall back to Wi-Fi.
- Physical receiver termination/relaunch over USB passed: closing the iPad process left only the primary display active; relaunching reattached the native-resolution display and resumed receiving frames with zero reported pipeline drops. This simulates abrupt connection loss; a literal cable pull remains a separate acceptance check.
- Forced capture-process failure passed: the host automatically reconnected with compatible hardware capture and resumed frames without restarting either app. A subsequent host restart selected NVIDIA capture again. The faster capture path is now eligible on later reconnects after a 30-second cooldown instead of being disabled until app restart.
- A native oversized-window fixture exposed missing background-window layout handling. After the fix, a 2660 × 1830 window at an out-of-bounds position was fitted to the iPad's 2420 × 1668 work area. Window events are now bounded and debounced per window, without requiring foreground focus.
- Windows launch, ready, expanded Advanced options, copy feedback and failure recovery were rendered and inspected. Stopping restores controls; quitting preserves the next launch's automatic connection preference. The native iPad layout/input suite remains 99 passing tests on build 6; physical gesture/key acceptance is not inferred from simulator tests.

## Remaining device checks

- Sustained motion performance and receiver presentation rate; capture rate still fluctuates below 60 fps.
- Reopen after background/sleep, unplug/replug, Wi-Fi fallback, and portrait/landscape rotation.
- GPU/driver recovery and compatible encoder fallback on other hardware.

The target frame rate is separate from measured throughput. The host's local status snapshot reports encoded frame counts; unchanged desktop frames can be repeated by Desktop Duplication. Raw videos, contact details, device identifiers, local machine paths, and pairing keys are excluded from this report.
