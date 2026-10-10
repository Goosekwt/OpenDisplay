#!/usr/bin/env python3
"""OpenDisplay app icon: one geometry, written out as SVG, PNG and ICO.

Concept: two adjoining displays, a PC and an iPad, with one window spanning the seam,
so the pair reads as a single continuous workspace. The geometry below is the source;
every SVG and raster is generated from it.

    python assets/branding/generate.py [repo-root]
"""
from __future__ import annotations

import io
import json
import math
import struct
import sys
from dataclasses import dataclass
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

ROOT = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[2]
PRODUCT = ROOT
BRANDING = PRODUCT / "assets" / "branding"
XCASSETS = PRODUCT / "ipad" / "OpenDisplay" / "Assets.xcassets"
WINDOWS_ICO = PRODUCT / "windows" / "OpenDisplay.Host" / "OpenDisplay.ico"

CANVAS = 1024


@dataclass(frozen=True)
class Box:
    x0: float
    y0: float
    x1: float
    y1: float
    r: float

    def at(self, s: float, dx: float = 0, dy: float = 0) -> tuple[tuple[float, float, float, float], float]:
        return (self.x0 * s + dx, self.y0 * s + dy, self.x1 * s + dx, self.y1 * s + dy), self.r * s


@dataclass(frozen=True)
class Design:
    pc: Box
    ipad: Box
    window: Box
    title: float  # title-bar height; 0 for none
    shadow: bool


# Full detail, for 32 px and up. Units are a 1024 canvas. A 3:2 PC display and a
# portrait 3:4 iPad stand side by side on a shared baseline; the window crosses the seam.
FULL = Design(
    pc=Box(100, 308, 656, 692, 32),
    ipad=Box(688, 376, 924, 692, 52),
    window=Box(286, 434, 872, 638, 28),
    title=52,
    shadow=True,
)

# Optical variant for 16–24 px: larger shapes, wider seam, no title bar or shadow.
SMALL = Design(
    pc=Box(72, 290, 610, 734, 64),
    ipad=Box(690, 290, 952, 734, 72),
    window=Box(300, 420, 860, 604, 40),
    title=0,
    shadow=False,
)

BG_TOP = "#2D6BF4"
BG_BOTTOM = "#1535B4"
PANEL = "#FFFFFF"
WINDOW = "#2F86FF"
TITLE = "#1A5FE0"
SHADOW = "#0B1E66"
SHADOW_OPACITY = 0.34
SHADOW_BLUR = 22  # Gaussian standard deviation, canvas units
SHADOW_DY = 16
WINDOW_SHADOW_OPACITY = 0.16  # the window's lift, drawn only on the screens
WINDOW_SHADOW_BLUR = 10
WINDOW_SHADOW_DY = 6

ICO_SIZES = [16, 20, 24, 32, 40, 48, 64, 96, 128, 256]
SMALL_MAX = 24


def rgb(hex_color: str) -> tuple[int, int, int]:
    h = hex_color.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def solid(n: int, color: str) -> Image.Image:
    return Image.new("RGB", (n, n), rgb(color))


def box_mask(n: int, box: Box, s: float) -> Image.Image:
    mask = Image.new("L", (n, n), 0)
    rect, r = box.at(s)
    ImageDraw.Draw(mask).rounded_rectangle(rect, radius=r, fill=255)
    return mask


def draw_art(n: int, design: Design) -> Image.Image:
    """Full-bleed square artwork at n × n pixels (draw large, then downsample)."""
    s = n / CANVAS
    gradient = Image.linear_gradient("L").resize((n, n), Image.BICUBIC)
    art = Image.composite(solid(n, BG_BOTTOM), solid(n, BG_TOP), gradient)

    screens = ImageChops.lighter(box_mask(n, design.pc, s), box_mask(n, design.ipad, s))
    if design.shadow:
        shadow = screens.filter(ImageFilter.GaussianBlur(SHADOW_BLUR * s))
        shadow = ImageChops.offset(shadow, 0, round(SHADOW_DY * s))
        art.paste(solid(n, SHADOW), (0, 0), shadow.point(lambda v: round(v * SHADOW_OPACITY)))
    art.paste(solid(n, PANEL), (0, 0), screens)

    # The window is clipped by the screens, so the seam cuts through it.
    window_shape = box_mask(n, design.window, s)
    if design.shadow:
        lift = window_shape.filter(ImageFilter.GaussianBlur(WINDOW_SHADOW_BLUR * s))
        lift = ImageChops.offset(lift, 0, round(WINDOW_SHADOW_DY * s))
        lift = ImageChops.multiply(lift.point(lambda v: round(v * WINDOW_SHADOW_OPACITY)), screens)
        art.paste(solid(n, SHADOW), (0, 0), lift)
    window = ImageChops.multiply(window_shape, screens)
    art.paste(solid(n, WINDOW), (0, 0), window)
    if design.title:
        bar = Image.new("L", (n, n), 0)
        top = design.window.y0 * s
        ImageDraw.Draw(bar).rectangle((0, top, n, top + design.title * s), fill=255)
        art.paste(solid(n, TITLE), (0, 0), ImageChops.multiply(bar, window))
    return art


def render_square(size: int, design: Design = FULL) -> Image.Image:
    supersample = max(2, math.ceil(4096 / size)) if size < 1024 else 4
    return draw_art(size * supersample, design).resize((size, size), Image.LANCZOS)


def render_tile(size: int) -> Image.Image:
    """Windows tile: rounded square with transparent corners; small sizes use the optical variant."""
    design = SMALL if size <= SMALL_MAX else FULL
    supersample = max(4, math.ceil(2048 / size))
    n = size * supersample
    inset = 0 if size <= SMALL_MAX else round(n * 0.04)
    inner = n - 2 * inset
    tile = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    mask = Image.new("L", (n, n), 0)
    ImageDraw.Draw(mask).rounded_rectangle((inset, inset, n - inset - 1, n - inset - 1), radius=inner * 0.22, fill=255)
    tile.paste(draw_art(inner, design), (inset, inset), mask.crop((inset, inset, inset + inner, inset + inner)))
    return tile.convert("RGBa").resize((size, size), Image.LANCZOS).convert("RGBA")


def squircle_mask(n: int, exponent: float = 5.0) -> Image.Image:
    """Approximates the iOS continuous-corner mask, for previews only."""
    points = []
    for i in range(1440):
        t = 2 * math.pi * i / 1440
        c, s = math.cos(t), math.sin(t)
        x = math.copysign(abs(c) ** (2 / exponent), c)
        y = math.copysign(abs(s) ** (2 / exponent), s)
        points.append((n / 2 + x * n / 2, n / 2 + y * n / 2))
    mask = Image.new("L", (n, n), 0)
    ImageDraw.Draw(mask).polygon(points, fill=255)
    return mask


# ---------------------------------------------------------------- SVG

def svg_rect(box: Box, fill: str = "", extra: str = "") -> str:
    fill_attr = f' fill="{fill}"' if fill else ""
    return (f'<rect x="{box.x0:g}" y="{box.y0:g}" width="{box.x1 - box.x0:g}" height="{box.y1 - box.y0:g}" '
            f'rx="{box.r:g}"{fill_attr}{extra}/>')


def svg(design: Design, title: str, tile_radius: float | None = None) -> str:
    w = design.window
    lines = [
        '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">',
        f"  <title>{title}</title>",
        "  <defs>",
        '    <linearGradient id="background" x1="0" y1="0" x2="0" y2="1">',
        f'      <stop offset="0" stop-color="{BG_TOP}"/>',
        f'      <stop offset="1" stop-color="{BG_BOTTOM}"/>',
        "    </linearGradient>",
        '    <clipPath id="screens">',
        f"      {svg_rect(design.pc)}",
        f"      {svg_rect(design.ipad)}",
        "    </clipPath>",
        f'    <clipPath id="window">{svg_rect(w)}</clipPath>',
    ]
    if design.shadow:
        lines += [
            '    <filter id="soft" x="-20%" y="-30%" width="140%" height="170%">',
            f'      <feGaussianBlur stdDeviation="{SHADOW_BLUR}"/>',
            "    </filter>",
            '    <filter id="lift" x="-10%" y="-20%" width="120%" height="150%">',
            f'      <feGaussianBlur stdDeviation="{WINDOW_SHADOW_BLUR}"/>',
            "    </filter>",
        ]
    if tile_radius is not None:
        lines.append(f'    <clipPath id="tile"><rect width="1024" height="1024" rx="{tile_radius:g}"/></clipPath>')
    lines.append("  </defs>")
    lines.append('  <g clip-path="url(#tile)">' if tile_radius is not None else "  <g>")
    lines.append('    <rect width="1024" height="1024" fill="url(#background)"/>')
    if design.shadow:
        lines += [
            f'    <g id="shadow" fill="{SHADOW}" opacity="{SHADOW_OPACITY:g}" filter="url(#soft)" transform="translate(0 {SHADOW_DY})">',
            f"      {svg_rect(design.pc)}",
            f"      {svg_rect(design.ipad)}",
            "    </g>",
        ]
    pc_rect = svg_rect(design.pc, extra=' id="pc"')
    ipad_rect = svg_rect(design.ipad, extra=' id="ipad"')
    lines += [
        f'    <g id="displays" fill="{PANEL}">',
        f"      {pc_rect}",
        f"      {ipad_rect}",
        "    </g>",
        '    <g id="spanning-window" clip-path="url(#screens)">',
    ]
    if design.shadow:
        lines.append(f'      <g fill="{SHADOW}" opacity="{WINDOW_SHADOW_OPACITY:g}" filter="url(#lift)" '
                     f'transform="translate(0 {WINDOW_SHADOW_DY})">{svg_rect(w)}</g>')
    lines += [
        f"      {svg_rect(w, WINDOW)}",
    ]
    if design.title:
        lines.append(f'      <rect x="{w.x0:g}" y="{w.y0:g}" width="{w.x1 - w.x0:g}" height="{design.title:g}" '
                     f'fill="{TITLE}" clip-path="url(#window)"/>')
    lines += ["    </g>", "  </g>", "</svg>", ""]
    return "\n".join(lines)


# ---------------------------------------------------------------- ICO

def dib(image: Image.Image) -> bytes:
    """32-bit BGRA DIB with an AND mask, the most widely supported ICO frame format."""
    w, h = image.size
    r, g, b, a = image.split()
    pixels = Image.merge("RGBA", (b, g, r, a)).tobytes()
    rows = [pixels[y * w * 4:(y + 1) * w * 4] for y in range(h)]
    alpha = a.tobytes()
    stride = ((w + 31) // 32) * 4
    masks = []
    for y in range(h - 1, -1, -1):
        bits = bytearray(stride)
        for x in range(w):
            if alpha[y * w + x] == 0:
                bits[x // 8] |= 0x80 >> (x % 8)
        masks.append(bytes(bits))
    header = struct.pack("<IiiHHIIiiII", 40, w, h * 2, 1, 32, 0, w * h * 4, 0, 0, 0, 0)
    return header + b"".join(reversed(rows)) + b"".join(masks)


def write_ico(path: Path, frames: list[Image.Image]) -> None:
    blobs = []
    for frame in frames:
        if frame.width >= 256:
            buffer = io.BytesIO()
            frame.save(buffer, "PNG", optimize=True)
            blobs.append(buffer.getvalue())
        else:
            blobs.append(dib(frame))
    offset = 6 + 16 * len(frames)
    directory = b""
    for frame, blob in zip(frames, blobs):
        side = frame.width if frame.width < 256 else 0
        directory += struct.pack("<BBBBHHII", side, side, 0, 0, 1, 32, len(blob), offset)
        offset += len(blob)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(struct.pack("<HHH", 0, 1, len(frames)) + directory + b"".join(blobs))


# ---------------------------------------------------------------- Preview

def font(size: int, bold: bool = False) -> ImageFont.ImageFont:
    for name in (("segoeuisb.ttf" if bold else "segoeui.ttf"), "arial.ttf"):
        try:
            return ImageFont.truetype(f"C:/Windows/Fonts/{name}", size)
        except OSError:
            continue
    return ImageFont.load_default()


def ios_preview_icon(art: Image.Image, size: int) -> Image.Image:
    icon = art.resize((size, size), Image.LANCZOS).convert("RGBA")
    big = squircle_mask(size * 4).resize((size, size), Image.LANCZOS)
    icon.putalpha(big)
    return icon


def drop_shadow(canvas: Image.Image, icon: Image.Image, xy: tuple[int, int], blur: float) -> None:
    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    alpha = icon.getchannel("A").point(lambda v: round(v * 0.22))
    shadow.paste((20, 30, 60, 255), (xy[0], xy[1] + round(blur * 0.5)), alpha)
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(blur)))
    canvas.alpha_composite(icon, xy)


def preview(art: Image.Image, tiles: dict[int, Image.Image]) -> Image.Image:
    width, height = 1800, 1060
    canvas = Image.new("RGBA", (width, height), (236, 237, 240, 255))
    draw = ImageDraw.Draw(canvas)
    label, heading = font(24), font(30, bold=True)
    ink, quiet = (40, 42, 48, 255), (110, 114, 122, 255)

    draw.text((90, 70), "OpenDisplay app icon", font=heading, fill=ink)
    draw.text((90, 112), "Two adjoining displays, one window spanning both.", font=label, fill=quiet)

    baseline = 760
    x = 90
    for size, caption in ((560, "Large · 560 px"), (180, "Home Screen · 180 px"),
                          (80, "Spotlight · 80 px"), (40, "Settings · 40 px")):
        icon = ios_preview_icon(art, size)
        drop_shadow(canvas, icon, (x, baseline - size), blur=max(4, size * 0.04))
        draw.text((x, baseline + 26), caption, font=label, fill=quiet)
        x += max(size + 90, 270)

    # Windows .ico frames: the 256 frame top right, small frames at 1:1 and zoomed 4×.
    canvas.alpha_composite(tiles[256], (width - 256 - 90, 70))
    draw.text((width - 256 - 90, 340), "Windows · 256 px", font=label, fill=quiet)
    draw.text((90, 870), "Windows .ico frames at 1:1, and 24 and 16 zoomed 4×", font=label, fill=ink)
    x = 90
    for size in (48, 32, 24, 16):
        canvas.alpha_composite(tiles[size], (x, 1000 - size))
        draw.text((x, 1012), f"{size}", font=font(20), fill=quiet)
        x += size + 40
    x += 40
    for size in (24, 16):
        zoomed = tiles[size].resize((size * 4, size * 4), Image.NEAREST)
        canvas.alpha_composite(zoomed, (x, 1000 - size * 4))
        draw.text((x, 1012), f"{size} × 4", font=font(20), fill=quiet)
        x += size * 4 + 40
    return canvas.convert("RGB")


# ---------------------------------------------------------------- Main

def main() -> None:
    BRANDING.mkdir(parents=True, exist_ok=True)

    (BRANDING / "OpenDisplay-AppIcon.svg").write_text(svg(FULL, "OpenDisplay app icon"), encoding="utf-8")
    (BRANDING / "OpenDisplay-AppIcon-small.svg").write_text(
        svg(SMALL, "OpenDisplay app icon, 16–24 px variant", tile_radius=1024 * 0.22), encoding="utf-8")

    art = render_square(1024)
    assert art.mode == "RGB" and art.size == (1024, 1024)
    art.save(BRANDING / "OpenDisplay-AppIcon-1024.png", optimize=True)

    tiles = {size: render_tile(size) for size in ICO_SIZES}
    write_ico(BRANDING / "OpenDisplay.ico", [tiles[s] for s in ICO_SIZES])
    WINDOWS_ICO.write_bytes((BRANDING / "OpenDisplay.ico").read_bytes())

    preview(art, tiles).save(BRANDING / "OpenDisplay-AppIcon-preview.png", optimize=True)

    iconset = XCASSETS / "AppIcon.appiconset"
    iconset.mkdir(parents=True, exist_ok=True)
    art.save(iconset / "AppIcon-1024.png", optimize=True)
    info = {"author": "xcode", "version": 1}
    (XCASSETS / "Contents.json").write_text(json.dumps({"info": info}, indent=2) + "\n", encoding="utf-8")
    (iconset / "Contents.json").write_text(json.dumps({
        "images": [{"filename": "AppIcon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}],
        "info": info,
    }, indent=2) + "\n", encoding="utf-8")

    # Self-check: the ICO parses with every frame, and the iOS artwork is opaque.
    with Image.open(BRANDING / "OpenDisplay.ico") as ico:
        print("ico sizes:", sorted(ico.info["sizes"]))
    print("1024 png:", art.mode, art.size)
    for path in sorted(BRANDING.iterdir()) + [WINDOWS_ICO, iconset / "AppIcon-1024.png"]:
        print(f"{path.stat().st_size:>8}  {path.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
