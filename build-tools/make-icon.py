#!/usr/bin/env python3
"""Generate VoiceInput app icon at 1024×1024.

Draws a rounded-square gradient background with a stylized microphone glyph.
Output goes to stdout's first argv path. Caller pipes through `sips` and
`iconutil` to produce the .icns.
"""

import sys
from PIL import Image, ImageDraw

SIZE = 1024
RADIUS = int(SIZE * 0.225)  # macOS continuous-corner radius proportion

# Green gradient — matches the floating-panel mic accent color.
TOP = (52, 199, 89)        # systemGreen
BOTTOM = (0, 145, 64)


def gradient_rounded_square(size: int, radius: int) -> Image.Image:
    """RGBA square with vertical gradient and rounded corners."""
    grad = Image.new("RGB", (size, size), TOP)
    for y in range(size):
        t = y / max(size - 1, 1)
        r = int(TOP[0] * (1 - t) + BOTTOM[0] * t)
        g = int(TOP[1] * (1 - t) + BOTTOM[1] * t)
        b = int(TOP[2] * (1 - t) + BOTTOM[2] * t)
        for x in range(size):
            grad.putpixel((x, y), (r, g, b))

    mask = Image.new("L", (size, size), 0)
    md = ImageDraw.Draw(mask)
    md.rounded_rectangle((0, 0, size - 1, size - 1), radius=radius, fill=255)

    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.paste(grad, (0, 0), mask)
    return out


def draw_mic(img: Image.Image) -> None:
    """Stylized white mic centered on `img`."""
    d = ImageDraw.Draw(img)
    cx = SIZE // 2
    cy = SIZE // 2 - int(SIZE * 0.04)

    # Capsule body — rounded rectangle, white.
    body_w = int(SIZE * 0.30)
    body_h = int(SIZE * 0.50)
    body_top = cy - body_h // 2
    body_bottom = cy + body_h // 2
    d.rounded_rectangle(
        (cx - body_w // 2, body_top, cx + body_w // 2, body_bottom),
        radius=body_w // 2,
        fill=(255, 255, 255, 255),
    )

    # Stand (U-shape arc beneath the body).
    arc_outer = int(SIZE * 0.42)
    arc_y = cy + int(SIZE * 0.08)
    arc_thickness = int(SIZE * 0.04)
    bbox_outer = (
        cx - arc_outer // 2,
        arc_y - arc_outer // 2,
        cx + arc_outer // 2,
        arc_y + arc_outer // 2,
    )
    d.arc(bbox_outer, start=20, end=160, fill=(255, 255, 255, 255), width=arc_thickness)

    # Stem under the arc.
    stem_top = arc_y + arc_outer // 2 - arc_thickness // 2
    stem_bottom = stem_top + int(SIZE * 0.08)
    stem_w = int(SIZE * 0.04)
    d.rectangle(
        (cx - stem_w // 2, stem_top, cx + stem_w // 2, stem_bottom),
        fill=(255, 255, 255, 255),
    )

    # Base bar.
    base_w = int(SIZE * 0.18)
    base_h = int(SIZE * 0.04)
    d.rounded_rectangle(
        (cx - base_w // 2, stem_bottom, cx + base_w // 2, stem_bottom + base_h),
        radius=base_h // 2,
        fill=(255, 255, 255, 255),
    )


def main() -> None:
    if len(sys.argv) != 2:
        print("usage: make-icon.py <output.png>", file=sys.stderr)
        sys.exit(2)
    img = gradient_rounded_square(SIZE, RADIUS)
    draw_mic(img)
    img.save(sys.argv[1], "PNG")
    print(f"Wrote {sys.argv[1]} ({SIZE}×{SIZE})")


if __name__ == "__main__":
    main()
