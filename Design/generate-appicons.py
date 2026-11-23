#!/usr/bin/env python3
"""
Generates SwiftPili's native Apple Icon Composer (.icon) bundles for all 5 AccentTheme variants.

Each .icon bundle contains pure, effect-free 1024x1024 vector SVG layers and a standard icon.json
manifest so iOS 26+ (and Xcode's actool fallback for iOS 18) render genuine Liquid Glass optics,
specular highlights, translucency, and Default/Dark/Clear/Tinted appearances.
"""

import json
import math
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
OUT_ROOT = REPO_ROOT / "SwiftPili" / "Resources" / "AppIcons"


def rounded_triangle_svg_path(vertices, corner_radius: float) -> str:
    pts = list(vertices)
    n = len(pts)
    segments = []
    for i in range(n):
        p_prev = pts[(i - 1) % n]
        p_curr = pts[i]
        p_next = pts[(i + 1) % n]

        v1 = (p_prev[0] - p_curr[0], p_prev[1] - p_curr[1])
        v2 = (p_next[0] - p_curr[0], p_next[1] - p_curr[1])
        l1 = math.hypot(*v1)
        l2 = math.hypot(*v2)
        u1 = (v1[0] / l1, v1[1] / l1)
        u2 = (v2[0] / l2, v2[1] / l2)

        dot = max(-1.0, min(1.0, u1[0] * u2[0] + u1[1] * u2[1]))
        alpha = math.acos(dot)
        tan_dist = corner_radius / math.tan(alpha / 2.0)

        t1 = (p_curr[0] + u1[0] * tan_dist, p_curr[1] + u1[1] * tan_dist)
        t2 = (p_curr[0] + u2[0] * tan_dist, p_curr[1] + u2[1] * tan_dist)

        sweep = math.pi - alpha
        k = (4.0 / 3.0) * math.tan(sweep / 4.0) * corner_radius
        c1 = (t1[0] - u1[0] * k, t1[1] - u1[1] * k)
        c2 = (t2[0] - u2[0] * k, t2[1] - u2[1] * k)

        segments.append((t1, c1, c2, t2))

    parts = [f"M {segments[0][0][0]:.2f} {segments[0][0][1]:.2f}"]
    for i in range(n):
        t1, c1, c2, t2 = segments[i]
        if i > 0:
            parts.append(f"L {t1[0]:.2f} {t1[1]:.2f}")
        parts.append(f"C {c1[0]:.2f} {c1[1]:.2f} {c2[0]:.2f} {c2[1]:.2f} {t2[0]:.2f} {t2[1]:.2f}")
    parts.append("Z")
    return " ".join(parts)


def make_disc_svg(fill_hex: str, radius: float = 372.0) -> str:
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">\n'
        f'  <circle cx="512" cy="512" r="{radius:.1f}" fill="{fill_hex}"/>\n'
        "</svg>\n"
    )


def make_play_svg(fill_hex: str, r_v: float = 286.0, corner_r: float = 48.0, cx: float = 494.0) -> str:
    cy = 512.0
    v_right = (cx + r_v * 0.98, cy)
    v_top = (cx - r_v * 0.52, cy - r_v * 0.87)
    v_bot = (cx - r_v * 0.52, cy + r_v * 0.87)
    d = rounded_triangle_svg_path([v_top, v_right, v_bot], corner_radius=corner_r)
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">\n'
        f'  <path d="{d}" fill="{fill_hex}"/>\n'
        "</svg>\n"
    )


def _srgb_to_linear(c: float) -> float:
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def _linear_to_srgb(c: float) -> float:
    c = max(0.0, min(1.0, c))
    return c * 12.92 if c <= 0.0031308 else 1.055 * (c ** (1.0 / 2.4)) - 0.055


def hex_to_p3(hex_str: str) -> str:
    """Converts sRGB hex color accurately into Display-P3 coordinates."""
    h = hex_str.lstrip("#")
    rs = _srgb_to_linear(int(h[0:2], 16) / 255.0)
    gs = _srgb_to_linear(int(h[2:4], 16) / 255.0)
    bs = _srgb_to_linear(int(h[4:6], 16) / 255.0)
    rp = _linear_to_srgb(0.822462 * rs + 0.177538 * gs)
    gp = _linear_to_srgb(0.033194 * rs + 0.966806 * gs)
    bp = _linear_to_srgb(0.017083 * rs + 0.072397 * gs + 0.910520 * bs)
    return f"display-p3:{rp:.5f},{gp:.5f},{bp:.5f},1.00000"


# 5 AccentTheme variants matching SwiftPili/SharedUI/Themes/Theme.swift
# V2 Design: Pure neutral light/dark canvas + whisper-tinted translucent optical glass disc + crisp theme-colored play prism
THEMES = [
    {
        "bundle": "AppIcon.icon",
        "theme": "bilibiliPink",
        # Theme.swift: #FB7299
        "disc_light": "#FB7299",
        "disc_dark": "#FB7299",
        "play_light": "#FA628F",
        "play_dark": "#FF7AA3",
        "disc_light_opacity": 0.16,
        "disc_dark_opacity": 0.20,
    },
    {
        "bundle": "AppIconPink.icon",
        "theme": "pink",
        # Theme.swift: #FCB0D9 (calibrated slightly deeper on white canvas for clean optical contrast)
        "disc_light": "#F594CA",
        "disc_dark": "#FBAEE0",
        "play_light": "#F284C2",
        "play_dark": "#FFB6E2",
        "disc_light_opacity": 0.18,
        "disc_dark_opacity": 0.20,
    },
    {
        "bundle": "AppIconGreen.icon",
        "theme": "green",
        # Theme.swift: #64BE7D
        "disc_light": "#55B870",
        "disc_dark": "#5DC77A",
        "play_light": "#48B567",
        "play_dark": "#6AD487",
        "disc_light_opacity": 0.16,
        "disc_dark_opacity": 0.20,
    },
    {
        "bundle": "AppIconOrange.icon",
        "theme": "orange",
        # Theme.swift: #F29D4B
        "disc_light": "#F2953D",
        "disc_dark": "#F59E49",
        "play_light": "#F08E34",
        "play_dark": "#FFA955",
        "disc_light_opacity": 0.16,
        "disc_dark_opacity": 0.20,
    },
    {
        "bundle": "AppIconRed.icon",
        "theme": "red",
        # Theme.swift: #E76060
        "disc_light": "#E75A5A",
        "disc_dark": "#EC6363",
        "play_light": "#E35050",
        "play_dark": "#F77070",
        "disc_light_opacity": 0.16,
        "disc_dark_opacity": 0.20,
    },
]


def build_bundle(spec: dict) -> None:
    bundle_dir = OUT_ROOT / spec["bundle"]
    assets_dir = bundle_dir / "Assets"
    assets_dir.mkdir(parents=True, exist_ok=True)

    (assets_dir / "disc-light.svg").write_text(make_disc_svg(spec["disc_light"]))
    (assets_dir / "disc-dark.svg").write_text(make_disc_svg(spec["disc_dark"]))
    (assets_dir / "play-light.svg").write_text(make_play_svg(spec["play_light"]))
    (assets_dir / "play-dark.svg").write_text(make_play_svg(spec["play_dark"]))

    icon_json = {
        "color-space-for-untagged-svg-colors": "display-p3",
        "fill-specializations": [
            {
                "value": {
                    "linear-gradient": [
                        hex_to_p3("#FFFFFF"),
                        hex_to_p3("#F1F2F6"),
                    ]
                }
            },
            {
                "appearance": "dark",
                "value": {
                    "linear-gradient": [
                        hex_to_p3("#25262B"),
                        hex_to_p3("#0E0F12"),
                    ]
                },
            },
        ],
        "groups": [
            {
                "layers": [
                    {
                        "glass": True,
                        "hidden-specializations": [
                            {"value": False},
                            {"appearance": "dark", "value": True},
                        ],
                        "image-name": "play-light.svg",
                        "name": "Play Light",
                    },
                    {
                        "glass": True,
                        "hidden-specializations": [
                            {"value": True},
                            {"appearance": "dark", "value": False},
                        ],
                        "image-name": "play-dark.svg",
                        "name": "Play Dark",
                    },
                ],
                "lighting": "individual",
                "opacity-specializations": [
                    {"value": 0.96},
                    {"appearance": "dark", "value": 0.98},
                ],
                "shadow": {
                    "kind": "neutral",
                    "opacity": 0.28,
                },
                "specular": True,
                "translucency": {
                    "enabled": True,
                    "value": 0.32,
                },
            },
            {
                "blur-material": 0.45,
                "layers": [
                    {
                        "glass": True,
                        "hidden-specializations": [
                            {"value": False},
                            {"appearance": "dark", "value": True},
                        ],
                        "image-name": "disc-light.svg",
                        "name": "Optical Disc Light",
                    },
                    {
                        "glass": True,
                        "hidden-specializations": [
                            {"value": True},
                            {"appearance": "dark", "value": False},
                        ],
                        "image-name": "disc-dark.svg",
                        "name": "Optical Disc Dark",
                    },
                ],
                "lighting": "individual",
                "opacity-specializations": [
                    {"value": spec["disc_light_opacity"]},
                    {"appearance": "dark", "value": spec["disc_dark_opacity"]},
                ],
                "shadow": {
                    "kind": "neutral",
                    "opacity": 0.14,
                },
                "specular": True,
                "translucency": {
                    "enabled": True,
                    "value": 0.80,
                },
            },
        ],
        "supported-platforms": {
            "circles": ["watchOS"],
            "squares": "shared",
        },
    }

    (bundle_dir / "icon.json").write_text(json.dumps(icon_json, indent=2) + "\n")
    print(f"Generated {bundle_dir.relative_to(REPO_ROOT)}")


if __name__ == "__main__":
    OUT_ROOT.mkdir(parents=True, exist_ok=True)
    for spec in THEMES:
        build_bundle(spec)
