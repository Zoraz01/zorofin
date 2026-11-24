#!/usr/bin/env python3
"""Regenerates the TV app's launcher icons, Android TV banner and LG icons
from the shared Zorofin branding (the same art as the Apple apps).

Run from the repository root: python3 apps/tv/tool/make_icons.py
Needs Pillow.
"""
from pathlib import Path
import shutil

from PIL import Image

root = Path(__file__).resolve().parents[3]
tv = root / "apps/tv"
icon = root / "apps/apple/Resources/iOS/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
wordmark = root / "branding/dist/wordmark.png"
mark = root / "branding/dist/mark-512.png"
# Background colour of the Apple TV app icon.
background = (12, 16, 15, 255)

# In-app artwork.
shutil.copyfile(mark, tv / "assets/images/mark-512.png")
shutil.copyfile(wordmark, tv / "assets/images/wordmark.png")

square = Image.open(icon).convert("RGBA")

def save_square(path, size):
    square.resize((size, size), Image.LANCZOS).save(path, optimize=True)

res = tv / "android/app/src/main/res"
for folder, size in {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}.items():
    save_square(res / f"mipmap-{folder}/ic_launcher.png", size)

# Android TV / Fire TV banner: 320x180 with the wordmark, as Google asks.
banner = Image.new("RGBA", (320, 180), background)
word = Image.open(wordmark).convert("RGBA")
word.thumbnail((264, 120), Image.LANCZOS)
banner.alpha_composite(word, ((320 - word.width) // 2, (180 - word.height) // 2))
banner.convert("RGB").save(res / "drawable-xhdpi/tv_banner.png", optimize=True)

save_square(tv / "webos/meta/icon.png", 80)
save_square(tv / "webos/meta/largeIcon.png", 130)
print("Icons written.")
