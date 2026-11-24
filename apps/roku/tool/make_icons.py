#!/usr/bin/env python3
"""Builds the white interface icons in images/icons/ (committed).

Run from apps/roku after `npm ci`: python3 tool/make_icons.py
Needs cairosvg and Pillow (pip install cairosvg pillow). Glyphs come from
lucide-static (ISC license, a devDependency) plus the Support headset shared
with the Apple apps. Icons are drawn white at 64 px so a Poster's blendColor
can tint them; the Apple TV app uses the matching SF Symbols.
"""
import io
import re
from pathlib import Path

import cairosvg
from PIL import Image, ImageChops

ROOT = Path(__file__).resolve().parents[1]
LUCIDE = ROOT / "node_modules" / "lucide-static" / "icons"
SUPPORT = ROOT.parent / "apple" / "Resources" / "tvOS" / "Assets.xcassets" / "Support.imageset" / "Support.svg"
OUT = ROOT / "images" / "icons"
SIZE = 64

# Roku name -> lucide glyph (Apple TV SF Symbol in the comment).
GLYPHS = {
    "play": "play",                     # play.fill (filled below)
    "info": "info",                     # info.circle
    "heart": "heart",                   # heart
    "check": "circle-check",            # checkmark.circle
    "restart": "rotate-ccw",            # arrow.counterclockwise
    "audio": "audio-lines",             # waveform
    "subtitles": "captions",            # captions.bubble
    "episodes": "layers",               # rectangle.stack
    "search": "search",                 # magnifyingglass
    "bell": "bell",                     # bell
    "options": "sliders-horizontal",    # slider.horizontal.3
    "close": "x",
    "users": "users",                   # person.2
    "settings": "settings",             # gearshape
    "key": "key-round",                 # Quick Connect
    "signout": "log-out",
    "chevron-down": "chevron-down",
    "chevron-left": "chevron-left",
    "chevron-right": "chevron-right",
    "guide": "calendar-days",
    "clock": "clock",
    "star": "star",
    "trophy": "trophy",
    "film": "film",
    "tv": "tv-minimal",
    "live": "radio",
    "list": "list-video",
    "gauge": "gauge",
    "more": "ellipsis",
    "server": "server",
    "phone": "smartphone-nfc",
    "message": "message-square-text",
    "alert": "circle-alert",
    "refresh": "refresh-cw",
    "offline": "wifi-off",
    "plus": "plus",
    "user": "user",                     # person.fill
    "display": "monitor",               # display
    "playback": "circle-play",          # play.circle.fill
    "controls": "gamepad-2",            # gamecontroller
    "storage": "hard-drive",            # internaldrive
    "privacy": "hand",                  # hand.raised
    "help": "circle-help",              # questionmark.circle
    "lock": "lock",
}
FILLED = {"play", "heart", "star"}


def render(svg: str, size: int = SIZE) -> Image.Image:
    png = cairosvg.svg2png(bytestring=svg.encode(), output_width=size, output_height=size)
    return Image.open(io.BytesIO(png)).convert("RGBA")


def white(svg: str, filled: bool = False) -> str:
    svg = svg.replace("currentColor", "#FFFFFF").replace("#000000", "#FFFFFF")
    if filled:
        svg = re.sub(r'fill="none"', 'fill="#FFFFFF"', svg, count=1)
    return svg


def save(img: Image.Image, name: str) -> None:
    # Keep only alpha; the colour is always white so blendColor tints exactly.
    alpha = img.getchannel("A")
    out = Image.new("RGBA", img.size, (255, 255, 255, 0))
    out.putalpha(alpha)
    out.save(OUT / f"{name}.png", optimize=True)


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    for name, glyph in GLYPHS.items():
        svg = (LUCIDE / f"{glyph}.svg").read_text()
        save(render(white(svg)), name)
        if name in FILLED:
            save(render(white(svg, filled=True)), f"{name}-filled")
    save(render(white(SUPPORT.read_text())), "support")

    # Watched: a solid disc with the check cut out (checkmark.circle.fill).
    check = render(white((LUCIDE / "check.svg").read_text()), 40)
    disc = Image.new("L", (SIZE * 4, SIZE * 4), 0)
    from PIL import ImageDraw
    ImageDraw.Draw(disc).ellipse([8, 8, SIZE * 4 - 9, SIZE * 4 - 9], fill=255)
    disc = disc.resize((SIZE, SIZE), Image.LANCZOS)
    hole = Image.new("L", (SIZE, SIZE), 0)
    hole.paste(check.getchannel("A"), (12, 12))
    alpha = ImageChops.subtract(disc, hole)
    out = Image.new("RGBA", (SIZE, SIZE), (255, 255, 255, 0))
    out.putalpha(alpha)
    out.save(OUT / "check-filled.png", optimize=True)


if __name__ == "__main__":
    main()
