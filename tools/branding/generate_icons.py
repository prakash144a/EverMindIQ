#!/usr/bin/env python3
"""Regenerates every MemoriesIQ app icon from the one definition below.

The mark is "Rings": three concentric circles — a sage-on-sage outer ring, a
gold middle ring, and a solid centre. Tree rings and sound rings are the same
drawing, which is the product in one shape; the gold ring is the year that
mattered, so the accent means here exactly what it means on a starred milestone
inside the app.

Everything is generated because an icon that exists only as five PNGs is an
icon nobody can change. The geometry lives in RINGS, the colours in the block
below it, and every output — Android vector drawables, the legacy mipmaps, the
web icons, and the data URI the marketing site inlines — is derived from those.
Change a number here and re-run; do not hand-edit anything this script writes.

    python tools/branding/generate_icons.py

Rasterising needs a Chromium: it looks for $BROWSER, then Edge, then Chrome.
There is no Python imaging dependency on purpose — this repo has no build step
and this script should not be the thing that introduces one.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ANDROID_RES = ROOT / "app" / "android" / "app" / "src" / "main" / "res"
WEB = ROOT / "app" / "web"

# -- the mark -----------------------------------------------------------------
# Radii and stroke on a 100x100 box centred at (50,50). The outer ring's outer
# edge lands at 44.75, so the mark's own diameter is 89.5 of the 100 box; every
# placement below is expressed against that rather than against the raw radius.
RINGS = dict(outer_r=41.0, mid_r=28.0, dot_r=9.0, stroke=7.5)
MARK_DIAMETER = (RINGS["outer_r"] + RINGS["stroke"] / 2) * 2 / 100  # 0.895

FG = "#ffffff"        # rings on the brand tile
ACCENT = "#f0cb85"    # the gold ring, lightened to hold up on sage
GRADIENT = ("#4f9a6c", "#40835a", "#2b5c40")  # 150deg, mid stop at 46%

# How much of a canvas the mark spans, per context. Adaptive and maskable get
# less because a launcher mask crops them: Android shows a 66/108 circle, and
# the web maskable spec guarantees only the centre 80%.
SPAN_TILE = 0.62       # legacy launcher icons, web icons, favicon, site header
SPAN_MASKABLE = 0.58   # web maskable
ADAPTIVE_MARK_DP = 60  # of the 108dp adaptive canvas


def _mark_svg(size: float, span: float) -> str:
    """The three circles, scaled to span `span` of a `size`-wide canvas."""
    s = size * span / 100
    o = size / 2 - 50 * s  # so the 100-box centre lands on the canvas centre
    def c(r, **kw):
        attrs = " ".join(f'{k.replace("_", "-")}="{v}"' for k, v in kw.items())
        return f'<circle cx="{50 * s + o:.4f}" cy="{50 * s + o:.4f}" r="{r * s:.4f}" {attrs}/>'
    return (
        c(RINGS["outer_r"], fill="none", stroke=FG, stroke_width=f'{RINGS["stroke"] * s:.4f}')
        + c(RINGS["mid_r"], fill="none", stroke=ACCENT, stroke_width=f'{RINGS["stroke"] * s:.4f}')
        + c(RINGS["dot_r"], fill=FG)
    )


def tile_svg(size: int = 512, rounded: bool = True, span: float = SPAN_TILE) -> str:
    """The full app tile: gradient ground, rounded unless it will be masked."""
    radius = f' rx="{size * 0.225:.4f}"' if rounded else ""
    g0, g1, g2 = GRADIENT
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" '
        f'viewBox="0 0 {size} {size}">'
        f'<defs><linearGradient id="g" x1="0" y1="0" x2="0.75" y2="1">'
        f'<stop offset="0" stop-color="{g0}"/><stop offset="0.46" stop-color="{g1}"/>'
        f'<stop offset="1" stop-color="{g2}"/></linearGradient></defs>'
        f'<rect width="{size}" height="{size}"{radius} fill="url(#g)"/>'
        + _mark_svg(size, span)
        + "</svg>"
    )


# -- rasterising --------------------------------------------------------------

BROWSERS = [
    os.environ.get("BROWSER"),
    r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
    r"C:\Program Files\Microsoft\Edge\Application\msedge.exe",
    r"C:\Program Files\Google\Chrome\Application\chrome.exe",
    "/usr/bin/google-chrome",
    "/usr/bin/chromium",
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
]


def find_browser() -> str:
    for b in BROWSERS:
        if b and Path(b).exists():
            return b
        if b and shutil.which(b):
            return shutil.which(b)
    sys.exit("No Chromium found. Set $BROWSER to a Chrome or Edge binary.")


BASE = 512  # every page is laid out at 512 CSS px and scaled by the device ratio


def rasterise(svg: str, out: Path, size: int, browser: str, workdir: Path) -> None:
    """Render `svg` to a `size`x`size` PNG with transparent corners.

    The page is always 512 CSS px and the device scale factor does the resizing,
    so Chromium rasterises the vector at the target size rather than downsampling
    a large bitmap. 512 over every size we emit is an exact binary fraction, so
    no rounding creeps into the output dimensions.
    """
    page = workdir / f"{out.stem}-{size}.html"
    page.write_text(
        "<!doctype html><meta charset=utf-8>"
        f"<style>html,body{{margin:0;width:{BASE}px;height:{BASE}px;background:transparent}}"
        f"svg{{display:block;width:{BASE}px;height:{BASE}px}}</style>" + svg,
        encoding="utf-8",
    )
    subprocess.run(
        [
            browser,
            "--headless=new",
            "--disable-gpu",
            "--hide-scrollbars",
            "--default-background-color=00000000",
            f"--user-data-dir={workdir / 'profile'}",
            f"--window-size={BASE},{BASE}",
            f"--force-device-scale-factor={size / BASE}",
            f"--screenshot={out}",
            page.as_uri(),
        ],
        capture_output=True,
        check=True,
    )
    if not out.exists():
        sys.exit(f"Chromium wrote nothing for {out}")
    print(f"  {out.relative_to(ROOT)}  {size}x{size}")


# -- Android vector drawables -------------------------------------------------

ADAPTIVE = 108.0


def _circle_path(cx: float, cy: float, r: float) -> str:
    """A full circle as VectorDrawable path data — it has no <circle>."""
    return f"M{cx - r:.3f},{cy:.3f} a{r:.3f},{r:.3f} 0 1,0 {2 * r:.3f},0 a{r:.3f},{r:.3f} 0 1,0 {-2 * r:.3f},0"


def _adaptive_paths(fg: str, accent: str) -> str:
    # Scale so the mark spans ADAPTIVE_MARK_DP of the 108dp canvas, which keeps
    # it inside the 66dp circle every launcher mask is guaranteed to show.
    s = (ADAPTIVE_MARK_DP / ADAPTIVE) / MARK_DIAMETER
    c = ADAPTIVE / 2
    sw = RINGS["stroke"] * s
    return f"""
  <path
      android:pathData="{_circle_path(c, c, RINGS['outer_r'] * s)}"
      android:strokeColor="{fg}"
      android:strokeWidth="{sw:.3f}"/>
  <path
      android:pathData="{_circle_path(c, c, RINGS['mid_r'] * s)}"
      android:strokeColor="{accent}"
      android:strokeWidth="{sw:.3f}"/>
  <path
      android:pathData="{_circle_path(c, c, RINGS['dot_r'] * s)}"
      android:fillColor="{fg}"/>"""


VECTOR_HEAD = (
    '<?xml version="1.0" encoding="utf-8"?>\n'
    "<!-- Generated by tools/branding/generate_icons.py. Do not edit by hand. -->\n"
    '<vector xmlns:android="http://schemas.android.com/apk/res/android"\n'
    '    android:width="108dp"\n'
    '    android:height="108dp"\n'
    '    android:viewportWidth="108"\n'
    '    android:viewportHeight="108">'
)


def write_android() -> None:
    drawable = ANDROID_RES / "drawable"
    drawable.mkdir(parents=True, exist_ok=True)
    g0, g1, g2 = (c.upper().replace("#", "#FF") for c in GRADIENT)

    (drawable / "ic_launcher_background.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        "<!-- Generated by tools/branding/generate_icons.py. Do not edit by hand. -->\n"
        '<vector xmlns:android="http://schemas.android.com/apk/res/android"\n'
        '    xmlns:aapt="http://schemas.android.com/aapt"\n'
        '    android:width="108dp"\n'
        '    android:height="108dp"\n'
        '    android:viewportWidth="108"\n'
        '    android:viewportHeight="108">\n'
        '  <path android:pathData="M0,0h108v108h-108z">\n'
        '    <aapt:attr name="android:fillColor">\n'
        '      <gradient\n'
        '          android:type="linear"\n'
        '          android:startX="0" android:startY="0"\n'
        '          android:endX="81" android:endY="108">\n'
        f'        <item android:offset="0" android:color="{g0}"/>\n'
        f'        <item android:offset="0.46" android:color="{g1}"/>\n'
        f'        <item android:offset="1" android:color="{g2}"/>\n'
        "      </gradient>\n"
        "    </aapt:attr>\n"
        "  </path>\n"
        "</vector>\n",
        encoding="utf-8",
    )

    (drawable / "ic_launcher_foreground.xml").write_text(
        VECTOR_HEAD + _adaptive_paths("#FFFFFFFF", "#FFF0CB85") + "\n</vector>\n", encoding="utf-8"
    )

    # Android 13+ themed icons: the system supplies the colour, so this layer is
    # a silhouette. The gold ring becomes the same value as the rest, which is
    # why the mark keeps real gaps between its rings rather than relying on hue.
    (drawable / "ic_launcher_monochrome.xml").write_text(
        VECTOR_HEAD + _adaptive_paths("#FF000000", "#FF000000") + "\n</vector>\n", encoding="utf-8"
    )

    anydpi = ANDROID_RES / "mipmap-anydpi-v26"
    anydpi.mkdir(parents=True, exist_ok=True)
    (anydpi / "ic_launcher.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        "<!-- Generated by tools/branding/generate_icons.py. Do not edit by hand. -->\n"
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '  <background android:drawable="@drawable/ic_launcher_background"/>\n'
        '  <foreground android:drawable="@drawable/ic_launcher_foreground"/>\n'
        '  <monochrome android:drawable="@drawable/ic_launcher_monochrome"/>\n'
        "</adaptive-icon>\n",
        encoding="utf-8",
    )
    for p in ("drawable/ic_launcher_background.xml", "drawable/ic_launcher_foreground.xml",
              "drawable/ic_launcher_monochrome.xml", "mipmap-anydpi-v26/ic_launcher.xml"):
        print(f"  {(ANDROID_RES / p).relative_to(ROOT)}")


# -- the site's inline mark ---------------------------------------------------

def site_data_uri() -> str:
    """The tile as a CSS-safe data URI.

    The marketing site ships no image files by design, so its favicon and header
    mark are this string inlined into the stylesheet and the page head.
    """
    svg = tile_svg(64).replace('"', "'").replace("#", "%23").replace("\n", "")
    return "data:image/svg+xml," + svg.replace("<", "%3C").replace(">", "%3E").replace("#", "%23")


# -- entry point --------------------------------------------------------------

LEGACY = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}


def main() -> None:
    browser = find_browser()
    print(f"Rasterising with {browser}")
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)

        print("Android adaptive + themed icons")
        write_android()

        print("Android legacy mipmaps (API 23-25)")
        for density, size in LEGACY.items():
            out = ANDROID_RES / f"mipmap-{density}" / "ic_launcher.png"
            out.parent.mkdir(parents=True, exist_ok=True)
            rasterise(tile_svg(), out, size, browser, work)

        print("Web icons")
        (WEB / "icons").mkdir(parents=True, exist_ok=True)
        for size in (192, 512):
            rasterise(tile_svg(), WEB / "icons" / f"Icon-{size}.png", size, browser, work)
            rasterise(
                tile_svg(rounded=False, span=SPAN_MASKABLE),
                WEB / "icons" / f"Icon-maskable-{size}.png",
                size, browser, work,
            )
        rasterise(tile_svg(), WEB / "favicon.png", 32, browser, work)

        print("Reference source")
        ref = Path(__file__).parent / "mark.svg"
        ref.write_text(tile_svg(512) + "\n", encoding="utf-8")
        print(f"  {ref.relative_to(ROOT)}")

    print("\nSite data URI (already inlined in site/styles.v3.css and the page heads):")
    print(site_data_uri())


if __name__ == "__main__":
    main()
