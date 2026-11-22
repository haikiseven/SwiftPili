# Shipping AppIcon — export pipeline

The app icon is **exported from the design document**, not generated from code.

- **Source of truth:** Claude Design project `9ed80318-03d8-4eae-b07b-25120e845c46`,
  file `Liquid Glass P.dc.html`, **section 5** (`4a + 4b → iOS App Icon`).
- **Icon glyphs:** `glyph-ic` (light) and `glyph-icd` (dark) — 4a's aperture
  refraction ring and caustics **plus** 4b's inner bevel, which is what gives the
  counter's hole wall thickness at small sizes.
- Sections 1–4 are the studies those glyphs derive from. Do not edit them to
  change the icon, and do not edit `glyph-b1`/`glyph-b2` — they are the 4a and 4b
  specimens and changing them silently changes section 4's own comparison.

## Why there is no procedural generator any more

`Design/appicon.py` used to draw a flat sky-blue P from code. It was deleted
because it made the repo a **second, competing source of truth**: anyone running
it would silently overwrite the shipped artwork with the pre-section-5 design.
Its docstring argued the artwork should stay flat because iOS supplies its own
material and baked-in gloss fights it — that argument was explicitly superseded
when the optical build became the thing to ship. If it is ever revived, it must
not write into `AppIcon.appiconset`.

## Running it

Needs Node and a headless Chrome. Chrome is not optional: the artwork is authored
as HTML+SVG for a browser canvas, and librsvg/resvg do not implement the
`feMorphology`-based edge and bevel filters the same way.

```bash
cd Design/export-appicon
npm install puppeteer                 # first time; downloads Chrome
python3 export.py "/path/to/Liquid Glass P.dc.html"   # emit render-*.html
node render.mjs                                       # rasterise at 1024²
python3 export.py --install                           # grayscale + install
```

`render.mjs` pins an explicit Chrome path; adjust it for your machine.

## Appearance mapping

| Asset | Design artboard | Base |
|---|---|---|
| `AppIcon.png` | 5a 浅色底 | opaque light gradient |
| `AppIcon-dark.png` | 5b 深黑底 | opaque near-black (`#0a0c10`) |
| `AppIcon-tinted.png` | — | transparent; grayscale matte, system tints it |

**One deliberate choice worth knowing.** The dark asset ships an **opaque**
near-black base because that is what section 5b draws. The deleted generator
instead left dark transparent so the system supplied the black glass. If the
system backdrop and this base ever disagree visibly on device, that is the knob —
it is a one-line change in `BASES["dark"]`, not a redesign.

## Verification before committing a new export

1. All three at 1024² and downsampled to 180 / 120 / 87.
2. The counter must stay legible at 87 px. Measured on the 2026-08-28 export as
   interior-vs-bowl luminance delta: light 38, dark 138, tinted 84.
3. Hashes must differ from the previous commit's assets.
