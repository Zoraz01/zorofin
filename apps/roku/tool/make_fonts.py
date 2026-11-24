#!/usr/bin/env python3
"""Builds static Inter weights for Roku from the shared variable font.

Roku cannot pick weights from a variable font, so this instantiates Regular,
SemiBold and Bold and subsets them to Latin, Greek and Cyrillic to keep the
channel package small. Needs fonttools (pip install fonttools).
Run: python3 apps/roku/tool/make_fonts.py
"""
from pathlib import Path
from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont
from fontTools import subset

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT.parent / "tv" / "assets" / "fonts" / "InterVariable.ttf"
OUT = ROOT / "fonts"
RANGES = [(0x20, 0x7E), (0xA0, 0x24F), (0x370, 0x3FF), (0x400, 0x4FF),
          (0x1E00, 0x1EFF), (0x2000, 0x206F), (0x20A0, 0x20BF), (0x2100, 0x215F),
          (0x2190, 0x21FF), (0x2212, 0x2212), (0x25A0, 0x25FF), (0x2600, 0x2606)]


def main():
    unicodes = [c for lo, hi in RANGES for c in range(lo, hi + 1)]
    for name, weight in [("Inter-Regular.ttf", 400), ("Inter-SemiBold.ttf", 600), ("Inter-Bold.ttf", 700)]:
        font = TTFont(SRC)
        loc = {"wght": weight}
        if "opsz" in {a.axisTag for a in font["fvar"].axes}:
            loc["opsz"] = 14 if weight < 600 else 32
        font = instantiateVariableFont(font, loc)
        opts = subset.Options()
        opts.layout_features = ["kern", "liga", "calt", "tnum"]
        opts.name_IDs = ["*"]
        sub = subset.Subsetter(opts)
        sub.populate(unicodes=unicodes)
        sub.subset(font)
        font.save(OUT / name)
        print(name, (OUT / name).stat().st_size)


if __name__ == "__main__":
    main()
