---
name: OpenDisplay
description: A familiar native utility for using an iPad as a Windows display.
colors:
  windows-surface: "#f7f8fa"
  windows-status: "#1c4880"
  windows-link: "#1450aa"
  windows-arrow: "#145dd7"
  windows-secondary-text: "#696969"
  video-background: "#000000"
  arrow-foreground: "#ffffff"
typography:
  windows-headline:
    fontFamily: "Segoe UI"
    fontSize: "25pt"
    fontWeight: 700
  windows-body:
    fontFamily: "Segoe UI"
    fontSize: "10pt"
    fontWeight: 400
  windows-section-label:
    fontFamily: "Segoe UI"
    fontSize: "10pt"
    fontWeight: 700
rounded:
  windows-arrow: "18px"
spacing:
  compact: "10px"
  control-gap: "12px"
  inset: "16px"
  section-gap: "24px"
  window-inset: "32px"
components:
  windows-action:
    typography: "{typography.windows-body}"
  windows-link:
    textColor: "{colors.windows-link}"
    typography: "{typography.windows-body}"
  windows-arrow:
    backgroundColor: "{colors.windows-arrow}"
    textColor: "{colors.arrow-foreground}"
    rounded: "{rounded.windows-arrow}"
    width: "152px"
    height: "92px"
---

# Design System: OpenDisplay

## Overview

**Creative North Star: "A familiar native display utility"**

The platform is the visual authority. Windows uses standard WinForms controls on a restrained light surface; iPad uses SwiftUI system views, symbols, forms, sheets, and materials. Familiar Duet-like utility behavior is the user's direction. There is no custom brand system to extend; the one exception is the app icon (see App Icon).

Keep the working display clear. Pairing and connection state receive attention while disconnected; video fills the iPad when available. Position arrows are temporary spatial indicators, separate from connection controls.

**Key Characteristics:**

- Familiar platform controls and typography.
- Clear connection state with optional settings disclosed separately.
- Full-screen video with temporary, unobtrusive overlays.

This is a source-derived snapshot dated 2026-10-10. Sources: `windows/OpenDisplay.Host/MainForm.cs`, `EdgeArrow.cs`, and `ipad/OpenDisplay/UI/*.swift` and `App/*.swift`. Windows previews at two sizes, the iPad simulator first-run screen, and the final icon preview were inspected. The Windows build and 20 core checks passed, including on GitHub's Windows runner; UI state simulations were checked. The iPad passed 63 simulator tests and development build 0.1.0 (3) installed on the owner's iPad. Final visual review cleared the instruction contrast and icon preview captions. The unsigned host is blocked by Windows Smart App Control; live connection and automatic sizing remain unverified. Described behavior below is implemented source behavior, not a claim of completed cross-device testing.

## Colors

Blue communicates links, connection feedback, and display direction; neutral surfaces keep the utility quiet.

- **Primary:** Windows link blue marks actions; status blue marks connection and copy feedback; the brighter arrow blue makes the temporary edge indicator visible.
- **Neutral:** Windows uses the light surface token and platform text defaults, with dim gray statistics. The video canvas is black; Windows arrow content is white.
- **iPad:** Preserve semantic `.systemGroupedBackground`, `.primary`/`.secondary`, `.blue`, `.red`, and `.regularMaterial` choices. Do not replace these with fixed light-mode hex values. The arrow explicitly uses white content on system blue; manual key errors use system red.

**The Platform Color Rule.** Fixed Windows colors belong to the host; iPad semantic colors and materials remain platform-resolved.

## Typography

Windows uses the frontmatter's Segoe UI roles: one bold headline, normal body copy, and bold section labels. The Windows arrow caption uses `SystemFonts.MessageBoxFont`.

iPad uses native text styles: body, monospaced body for the pairing key, subheadline with medium weight for connection summary, callout for scanner guidance, footnote for notices, and title3 for control symbols. The edge arrow alone has an explicit system symbol size (44 points, bold). Keep Dynamic Type and system text metrics; do not reproduce Windows headline styling on iPad.

## Layout

Windows starts with a client area of 960 × 690 and a minimum outer window size of 870 × 700, with DPI autoscaling. The root has a 32-unit inset, a 64%/36% two-column split, a 90-unit heading row, and a 58-unit action row. These are source layout units before DPI scaling, not screenshot pixel measurements. Connection state and Advanced options occupy the left; pairing occupies the right. Advanced content and the pairing column can scroll. The QR image fits its column, up to its DPI-scaled 248-unit size. There is no implemented narrow-screen column breakpoint.

iPad's video ignores safe areas. Disconnected states use centered `ContentUnavailableView` content; paired settings are available at the top trailing edge. Pairing and settings open in native sheets and navigation stacks. The connection capsule sits at the top with a 16-point inset. The arrow is centered on the appropriate physical screen edge with 24-point padding; left and right remain physical directions in right-to-left locales.

## Elevation & Depth

Windows content is flat; native window and control chrome supply their own depth. Do not add card shadows. iPad uses regular material for the connection capsule and scanner hint. Only the iPad position arrow has an explicit shadow: black at 35% opacity, radius 10, vertical offset 3. System sheets and menus keep native elevation.

## Shapes

Standard controls keep platform shapes. Windows' custom edge indicator is a rounded rectangle using the frontmatter radius. iPad's edge indicator is a circle (96 × 96 points); connection and scanner overlays are capsules. These overlays are not a general card style.

## Components

- **Windows actions:** Native buttons. Start/Stop connecting changes with the active connection loop; Show position arrows is disabled until connected. Both have minimum size 160 × 42 source units. Copy pairing key has minimum size 170 × 40. Hover, focus, pressed, and disabled appearance are native.
- **Advanced options:** An underlined link toggles a scrollable settings area, hidden initially. It contains display selection, display arrangement/setup links, mirror testing, Wi-Fi fallback, frame-rate target, and sign-in startup. Connection configuration fields disable while connecting; stopping or failure restores them.
- **Pairing:** A black-and-white QR code with an accessible alternative through Copy pairing key. Copy success or clipboard failure appears beside pairing content without replacing connection status. iPad provides QR scanning, a camera-permission fallback, and a native form for manual entry. Manual errors appear in the form footer.
- **iPad status:** Native `ContentUnavailableView` distinguishes unpaired, paused, waiting, connected-before-first-frame, and listener failure. Primary recovery/pairing actions use `.borderedProminent`; waiting uses `ProgressView`. A received first frame switches to video.
- **Connection capsule:** A summary and native menu appear when video begins or the user taps the video, then hide after four seconds. The menu offers local position-arrow replay, Settings, and Disconnect. It is separate from the arrow and is not a controls drawer attached to an edge.
- **Position arrows:** Windows shows a click-through, nonactivating edge window with a directional arrow and “iPad this way.” It closes after three seconds, fading over the final half-second. iPad shows a system arrow pointing toward the PC; requests govern its lifetime. Its spring entrance lasts 0.35 seconds and it nudges outward by 10 points on a repeating 0.7-second ease-in-out cycle. Reduce Motion removes the nudge and substitutes a 0.2-second opacity transition. iPad announces the direction for accessibility. Root video/control transitions use a 0.2-second ease-in-out fade.
- **Settings:** iPad uses a native Form with pairing, connection details, and a destructive Forget This PC confirmation. Windows closes to the notification area; its tray menu provides Open and Quit.

The sidecar's HTML previews are illustrative translations for documentation; its synthesized tonal ramps are preview aids, not implemented palette scales. Native APIs and these source files remain authoritative for system-rendered controls, dynamic colors, focus, and accessibility.

## App Icon

On 2026-10-10 the user explicitly asked for a custom app icon ("have Claude create a nice icon for it"). That request supersedes the earlier no-custom-branding instruction, but only for the icon; the interface stays native.

- **Concept:** two adjoining displays, a 3:2 PC display and a portrait iPad on a shared baseline, with one window crossing the seam between them. It reads as a single workspace spread across two screens. The icon has no text, initials or third-party marks.
- **Colors:** vertical cobalt gradient `#2D6BF4` → `#1535B4`, white displays, an azure window `#2F86FF` with a `#1A5FE0` title bar, and soft navy (`#0B1E66`) shadows at 34% and 16% opacity.
- **Sizes:** 32 px and up use the full design. The 16–24 px ICO frames use a simplified variant (larger shapes, wider seam, no title bar or shadows), so the tray icon stays legible.
- **Sources:** `assets/branding/OpenDisplay-AppIcon.svg` (editable vector, full-bleed), `OpenDisplay-AppIcon-small.svg`, the opaque 1024 px `OpenDisplay-AppIcon-1024.png` (iOS applies its own corner mask), `OpenDisplay.ico` (16–256 px) and `OpenDisplay-AppIcon-preview.png`. All are generated by `assets/branding/generate.py` using Python and Pillow; edit the geometry there rather than the rasters.
- **Use:** the iPad uses `Assets.xcassets/AppIcon.appiconset` (single 1024 px source). Windows uses the same ICO as the application icon, the window icon and the tray icon, loaded once and never disposed while in use (`AppIcon.cs`).

## Do's and Don'ts

- **Do** use native controls and semantic iPad styling for new surfaces.
- **Do** preserve the distinction between connection state and pairing feedback.
- **Do** keep optional connection configuration under Advanced on Windows.
- **Do** keep position arrows temporary, directional, and separate from menus.
- **Do** preserve native focus, disabled states, Dynamic Type, and Reduce Motion behavior.
- **Don't** add custom branding (beyond the user-requested app icon), decorative dashboards, or persistent chrome over the video.
- **Don't** turn a position arrow into a controls drawer.
- **Don't** treat source behavior, preview captures, or targets as verified live connection or performance results.
