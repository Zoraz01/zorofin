#!/usr/bin/env python3
"""Builds the Roku channel artwork from the shared Zorofin brand files.

Run from anywhere: python3 apps/roku/tool/make_images.py
Outputs go to apps/roku/images/ (committed). Sizes follow Roku's manifest
artwork rules: focus icons 336x210 (HD) and 540x405 (store poster), splash
1280x720 only: Roku scales it up on FHD, and a 1920x1080 splash stays in
texture memory (8.3 MB) for the whole session on some TVs.
"""
from pathlib import Path
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
BRAND = ROOT.parent / "tv" / "assets" / "images"
OUT = ROOT / "images"
APPLE_LOGO = ROOT.parent / "apple" / "Resources" / "tvOS" / "Assets.xcassets" / "HeaderLogo.imageset" / "HeaderLogo.png"
BG = (17, 21, 19, 255)       # Zoro.background
PANEL = (27, 33, 30, 255)    # Zoro.panel


def fit(img, box_w, box_h):
    img = img.copy()
    img.thumbnail((box_w, box_h), Image.LANCZOS)
    return img


def canvas(w, h, color=BG):
    return Image.new("RGBA", (w, h), color)


def centered(base, art, dy=0):
    x = (base.width - art.width) // 2
    y = (base.height - art.height) // 2 + dy
    base.alpha_composite(art, (x, y))
    return base


def main():
    OUT.mkdir(exist_ok=True)
    wordmark = Image.open(BRAND / "wordmark.png").convert("RGBA")
    mark = Image.open(BRAND / "mark-512.png").convert("RGBA")

    # Home-screen tiles (focus) and the store poster.
    for name, (w, h), pad in [
        ("icon_focus_hd.png", (336, 210), 0.80),
        ("icon_focus_fhd.png", (540, 405), 0.80),
        ("store_poster.png", (540, 405), 0.80),
    ]:
        tile = centered(canvas(w, h), fit(wordmark, int(w * pad), int(h * pad)))
        tile.convert("RGB").save(OUT / name, optimize=True)

    for name, (w, h) in [("splash_hd.png", (1280, 720))]:
        art = fit(wordmark, int(w * 0.42), int(h * 0.30))
        centered(canvas(w, h), art).convert("RGB").save(OUT / name, optimize=True)

    fit(wordmark, 360, 90).save(OUT / "wordmark.png", optimize=True)
    fit(mark, 160, 160).save(OUT / "mark.png", optimize=True)
    # Header symbol, the same artwork as the Apple TV HeaderLogo image set.
    header = Image.open(APPLE_LOGO).convert("RGBA")
    fit(header, 96, 96).save(OUT / "logo.png", optimize=True)

    # Rounded-rectangle 9-patch pieces used for focus rings, pills and panels.
    SS = 8  # supersampling so curved edges are anti-aliased, not stair-stepped

    def smooth_round(s, radius, fill, stroke, width):
        # Draw the shape at SS times the size and scale it down, which gives
        # the soft alpha edge a TV needs once it upscales 1080p to 4K.
        big = Image.new("RGBA", (s * SS, s * SS), (0, 0, 0, 0))
        ImageDraw.Draw(big).rounded_rectangle(
            [0, 0, s * SS - 1, s * SS - 1], radius=radius * SS, fill=fill,
            outline=stroke, width=width * SS)
        return big.resize((s, s), Image.LANCZOS)

    def marked(name, body, radius):
        # Android-style 9-patch, which Roku reads: a 1 px border whose black
        # pixels mark the stretchable middle row and column.
        s = body.width
        img = Image.new("RGBA", (s + 2, s + 2), (0, 0, 0, 0))
        img.alpha_composite(body, (1, 1))
        d = ImageDraw.Draw(img)
        lo, hi = radius + 1, s - radius
        d.line([(lo, 0), (hi, 0)], fill=(0, 0, 0, 255))
        d.line([(0, lo), (0, hi)], fill=(0, 0, 0, 255))
        img.save(OUT / name)

    def nine(name, radius, fill, stroke=None, width=0):
        marked(name, smooth_round(radius * 2 + 4, radius, fill, stroke, width), radius)

    def corner_mask(name, r):
        # Background-coloured corners around a rounded hole.
        s = r * 2 + 4
        hole = Image.new("L", (s * SS, s * SS), 0)
        ImageDraw.Draw(hole).rounded_rectangle([0, 0, s * SS - 1, s * SS - 1], radius=r * SS, fill=255)
        hole = hole.resize((s, s), Image.LANCZOS)
        body = Image.new("RGBA", (s, s), BG)
        body.putalpha(Image.eval(hole, lambda v: 255 - v))
        marked(name, body, r)

    nine("ring.9.png", 18, None, (255, 255, 255, 255), 5)
    nine("card_ring.9.png", 16, None, (255, 255, 255, 255), 4)

    # Corner masks over square artwork so cards read with rounded corners
    # without an expensive MaskGroup: 12 px for cards, 24 px for the banner.
    corner_mask("corners.9.png", 12)
    corner_mask("corners24.9.png", 24)

    # Circles for icon buttons and the avatar, drawn large and scaled down.
    big = 256
    disc = Image.new("L", (big * 2, big * 2), 0)
    ImageDraw.Draw(disc).ellipse([2, 2, big * 2 - 3, big * 2 - 3], fill=255)
    disc = disc.resize((big, big), Image.LANCZOS)
    circle = Image.new("RGBA", (big, big), (255, 255, 255, 0))
    circle.putalpha(disc)
    circle.save(OUT / "circle.png", optimize=True)
    ring = Image.new("L", (big * 2, big * 2), 0)
    ImageDraw.Draw(ring).ellipse([2, 2, big * 2 - 3, big * 2 - 3], outline=255, width=26)
    ring = ring.resize((big, big), Image.LANCZOS)
    circle_ring = Image.new("RGBA", (big, big), (255, 255, 255, 0))
    circle_ring.putalpha(ring)
    circle_ring.save(OUT / "circle_ring.png", optimize=True)
    # Circle outlines at 60 px: 1 px border and 3 px focus stroke.
    for name, width in [("circle_hair.png", 1), ("circle_stroke.png", 3)]:
        scale = 8
        size = 60 * scale
        line = Image.new("L", (size, size), 0)
        ImageDraw.Draw(line).ellipse([0, 0, size - 1, size - 1], outline=255, width=width * scale)
        line = line.resize((60, 60), Image.LANCZOS)
        out = Image.new("RGBA", (60, 60), (255, 255, 255, 0))
        out.putalpha(line)
        out.save(OUT / name, optimize=True)
    # Background-coloured corners around a round hole, for avatar photos.
    mask = Image.new("RGBA", (big, big), BG)
    mask.putalpha(Image.eval(disc, lambda v: 255 - v))
    mask.save(OUT / "circle_mask.png", optimize=True)
    nine("pill.9.png", 30, (255, 255, 255, 255))
    nine("badge.9.png", 7, (255, 255, 255, 255))
    nine("panel.9.png", 18, (255, 255, 255, 255))
    nine("card.9.png", 14, (255, 255, 255, 255))
    # Focus ring 6 px outside a 60 px navigation pill, 3 px wide.
    nine("pill_ring.9.png", 36, None, (255, 255, 255, 255), 3)
    nine("panel20.9.png", 20, (255, 255, 255, 255))
    # Capsule outlines for Apple's ZoroButtonStyle: 1 px border, 3 px focus.
    nine("pill_hair.9.png", 30, None, (255, 255, 255, 255), 1)
    # FlatOptionStyle: 10 px corners, 2 px focus stroke.
    nine("option.9.png", 10, (255, 255, 255, 255))
    nine("option_ring.9.png", 10, None, (255, 255, 255, 255), 2)
    # GuideCellStyle (Live TV guide): 10 px corners, 1 px border, 3 px focus.
    nine("option_hair.9.png", 10, None, (255, 255, 255, 255), 1)
    nine("option_stroke.9.png", 10, None, (255, 255, 255, 255), 3)
    nine("popover.9.png", 24, (255, 255, 255, 255))
    nine("popover_hair.9.png", 24, None, (255, 255, 255, 255), 1)
    nine("panel_hair.9.png", 20, None, (255, 255, 255, 255), 1)
    nine("pill_stroke.9.png", 30, None, (255, 255, 255, 255), 3)

    # Home banner shade: clear at the top to 92% black at the bottom.
    shade = Image.new("RGBA", (16, 480))
    px = shade.load()
    for y in range(480):
        t = y / 479
        a = 0.15 * min(1, t / 0.5) if t < 0.5 else 0.15 + (0.92 - 0.15) * (t - 0.5) / 0.5
        for x in range(16):
            px[x, y] = (0, 0, 0, int(255 * a))
    shade.save(OUT / "hero_shade.png", optimize=True)

    # Gradient scrims for hero artwork. Kept thin and stretched by the Poster:
    # a full-screen PNG costs 8 MB of the Roku's ~100 MB texture memory.
    left = Image.new("RGBA", (480, 4))
    px = left.load()
    for x in range(480):
        a = max(0, min(255, int(255 * (1.15 - x * 4 / 1100))))
        for y in range(4):
            px[x, y] = (17, 21, 19, a)
    left.save(OUT / "scrim_left.png", optimize=True)
    bottom = Image.new("RGBA", (4, 270))
    px = bottom.load()
    for y in range(270):
        a = max(0, min(255, int(255 * (y / 270) ** 1.4)))
        for x in range(4):
            px[x, y] = (17, 21, 19, a)
    bottom.save(OUT / "scrim_bottom.png", optimize=True)


if __name__ == "__main__":
    main()
