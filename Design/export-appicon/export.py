#!/usr/bin/env python3
"""Export the shipping AppIcon from the DESIGN DOCUMENT — the source of truth.

The icon is NOT generated procedurally any more. `Design/appicon.py` used to
draw a flat sky-blue P from code, which made the repo a second, competing
source of truth: it could silently overwrite the shipped artwork with the
pre-section-5 design. It was deleted for that reason, not because the drawing
was wrong.

Source of truth: Claude Design project `9ed80318-03d8-4eae-b07b-25120e845c46`,
file `Liquid Glass P.dc.html`, section 5 (`4a + 4b -> iOS App Icon`). The icon
glyphs are `glyph-ic` (light) and `glyph-icd` (dark) — 4a's aperture refraction
ring and caustics plus 4b's inner bevel. Sections 1-4 are the studies those are
derived from and must not be edited to change the icon.

    python3 export.py <path-to-Liquid Glass P.dc.html> [--install]

Stage 1 (this script, no --install): resolve the canvas runtime props and emit
render-{light,dark,tinted}.html.
Stage 2: `node render.mjs` — headless Chrome rasterises them at 1024x1024.
Chrome is the faithful renderer because the artwork is authored as HTML+SVG for
a browser canvas; librsvg/resvg do not implement the feMorphology-based edge and
bevel filters the same way.
Stage 3 (this script with --install): grayscale the tinted matte and copy all
three into SwiftPili/Resources/Assets.xcassets/AppIcon.appiconset/.
"""
import re
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
APPICONSET = REPO / "SwiftPili/Resources/Assets.xcassets/AppIcon.appiconset"

S = 1024                 # master resolution
GLYPH_FRACTION = 0.78    # section 5: "P 占 78% 光学居中"
ARTBOARD = 228.0         # the section-5 artboard box the ratios come from
ARTBOARD_GLYPH = 178.0

# The canvas runtime's documented defaults (data-props + renderVals):
# clarity 0.5 -> smokeOpacity = 1 - 0.5*0.5; edgeIntensity 1; lightAngle 0.
PROPS = {"smokeOpacity": "0.75", "edgeOpacity": "1", "lightRot": "0"}

BASES = {
    # name: (background, box-shadow, glyph id)
    "light": (
        "linear-gradient(150deg,#fdfdfd 0%,#f4f4f5 46%,#e6e7ea 100%)",
        "inset 0 {i:.2f}px 0 rgba(255,255,255,.9),inset 0 -{i:.2f}px 0 rgba(0,0,0,.05)",
        "glyph-ic",
    ),
    "dark": (
        "radial-gradient(120% 100% at 26% 6%,rgba(255,255,255,.08),"
        "rgba(255,255,255,0) 50%),#0a0c10",
        "inset 0 {i2:.2f}px 0 rgba(255,255,255,.2)",
        "glyph-icd",
    ),
    # tinted carries no base: iOS supplies the backdrop and applies the tint.
    # The white-glass build is used because its luminance already reads as a
    # matte, so the optical structure survives the grayscale collapse.
    "tinted": ("transparent", "none", "glyph-icd"),
}


def extract_defs(doc: Path) -> str:
    src = doc.read_text()
    match = re.search(r'(<svg width="0" height="0".*?</defs></svg>)', src, re.S)
    if not match:
        sys.exit("could not find the hidden <defs> block in the design document")
    defs = match.group(1)
    for key, value in PROPS.items():
        defs = defs.replace("{{ %s }}" % key, value)
    if "{{" in defs:
        sys.exit("unresolved canvas template prop remains in the defs")
    return defs


def write_pages(defs: str) -> None:
    glyph = GLYPH_FRACTION * S
    dx = (2.0 / ARTBOARD_GLYPH) * glyph      # artboard translateX(2px), scaled
    inset = 1.0 * (S / ARTBOARD)             # artboard hairlines, scaled
    for name, (background, shadow, glyph_id) in BASES.items():
        (HERE / f"render-{name}.html").write_text(
            "<!doctype html><html><head><meta charset=\"utf-8\"><style>\n"
            "*{margin:0;padding:0}\n"
            f"html,body{{width:{S}px;height:{S}px;background:transparent}}\n"
            f"#icon{{width:{S}px;height:{S}px;display:grid;place-items:center;"
            f"background:{background};"
            f"box-shadow:{shadow.format(i=inset, i2=2 * inset)};overflow:hidden}}\n"
            "</style></head><body>\n"
            f"{defs}\n"
            f"<div id=\"icon\"><svg viewBox=\"0 0 1000 1000\" width=\"{glyph:.2f}\""
            f" height=\"{glyph:.2f}\" style=\"display:block;overflow:visible;"
            f"transform:translateX({dx:.2f}px)\">\n"
            f"<use href=\"#{glyph_id}\" width=\"1000\" height=\"1000\"></use>"
            "</svg></div>\n</body></html>\n"
        )
        print(f"wrote render-{name}.html  glyph={glyph_id}")


def install() -> None:
    from PIL import Image
    import numpy as np

    tinted = HERE / "out-tinted.png"
    image = Image.open(tinted).convert("RGBA")
    pixels = np.asarray(image).astype(np.float32)
    luminance = (
        0.2126 * pixels[..., 0] + 0.7152 * pixels[..., 1] + 0.0722 * pixels[..., 2]
    )
    Image.fromarray(
        np.dstack([luminance, luminance, luminance, pixels[..., 3]])
        .clip(0, 255)
        .astype(np.uint8),
        "RGBA",
    ).save(tinted)
    print("tinted -> grayscale matte (alpha preserved)")

    for source, target in (
        ("out-light.png", "AppIcon.png"),
        ("out-dark.png", "AppIcon-dark.png"),
        ("out-tinted.png", "AppIcon-tinted.png"),
    ):
        shutil.copyfile(HERE / source, APPICONSET / target)
        print(f"installed {target}")


if __name__ == "__main__":
    if "--install" in sys.argv:
        install()
    elif len(sys.argv) > 1:
        write_pages(extract_defs(Path(sys.argv[1])))
    else:
        sys.exit(__doc__)
