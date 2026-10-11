# Capture validation — 11 October 2026

## Verified

- Physical USB playback and position-arrow activation confirmed by the owner. The owner describes GPU capture as smoother.
- Independent physical-pixel geometry: the laptop remains 2880 × 1800, and the iPad virtual display is 2420 × 1668. The user's left-side arrangement is preserved.
- Scaling adjustment read back successfully: only the virtual display changed from 125% to 200%; the physical display remained at 200%. The final visual size still needs owner acceptance.
- DXGI maps the virtual display to the NVIDIA GPU, independently of the AMD GPU driving the laptop. Native capture uses that exact adapter/output pair.
- Direct capture produced roughly 46–48 encoded frames/second in short isolated tests without FFmpeg frame duplication. A live USB sample measured about 33–35 encoded frames/second at native resolution. Neither is a claim of 60 unique frames/second or iPad presentation rate.
- The new Windows circular arrow completed its three-second native compositor check with 189 successful updates, no presentation errors, and disposed its window. Four directional artwork previews were inspected. Final user acceptance remains pending.
- Windows publish and 25 core checks pass. Tests cover encrypted streams, rejection of malformed/replayed records, display mode selection, edge direction, and keeping left/top/right/bottom layouts attached through resizing.
- Claude Code transferred a synthetic 2420 × 1668, 60-fps NVENC fixture to the owner's Mac mini and ran the receiver's parser, assembler, sample builder, pipeline, and VideoToolbox decoder against it. All 120 pictures parsed and decoded at the correct dimensions with zero decode errors and no pipeline drops. Fragmented chunks produced identical access units. This validates the stream format on that Mac; it is not a physical iPad frame-rate measurement.

## Remaining device checks

- Final desktop/cursor size and matching Windows/iPad arrow experience.
- Sustained motion performance and receiver presentation rate; capture rate still fluctuates below 60 fps.
- Reopen after background/sleep, unplug/replug, Wi-Fi fallback, and portrait/landscape rotation.
- GPU/driver recovery and compatible encoder fallback on other hardware.

The target frame rate is separate from measured throughput. The host's local status snapshot reports encoded frame counts; unchanged desktop frames can be repeated by Desktop Duplication. Raw videos, contact details, device identifiers, local machine paths, and pairing keys are excluded from this report.
