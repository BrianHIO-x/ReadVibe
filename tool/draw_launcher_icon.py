"""Draw the ReadVibe launcher icon master (flat vector shapes, no dependencies
beyond Pillow).

Usage:
    python tool/draw_launcher_icon.py            # master only
    python tool/draw_launcher_icon.py --install  # master + Android res sizes

The master lands in design/readvibe-icon.png at 1024x1024. --install also writes
the mipmap-*/ic_launcher.png set (legacy launchers, opaque square) and
drawable-nodpi/readvibe_mark.png (the adaptive foreground, transparent), each
downsampled from one 4096px render so the ground colour stays byte-exact against
colors.xml.

Palette follows lib/theme/app_theme.dart: terracotta ground #B3543A, warm cream
pages #FAF7F2.

Two framings, because Android crops them differently. The legacy square keeps the
mark at 58% of the canvas. The adaptive foreground is a 108dp canvas of which only
the centre 72dp survives, and a circular mask eats the corners of that, so the
mark is scaled down until it fits inside the 66dp safe circle.
"""

import os
import sys

from PIL import Image, ImageDraw

CANVAS = 1024          # logical units
SUPERSAMPLE = 4        # drawn at 4x, downsampled with Lanczos

GROUND = "#B3543A"     # AppTheme.accent
PAGE = "#FAF7F2"       # AppTheme.background


def cubic(p0, p1, p2, p3, steps=64):
    points = []
    for i in range(1, steps + 1):
        t = i / steps
        m = 1 - t
        x = m*m*m*p0[0] + 3*m*m*t*p1[0] + 3*m*t*t*p2[0] + t*t*t*p3[0]
        y = m*m*m*p0[1] + 3*m*m*t*p1[1] + 3*m*t*t*p2[1] + t*t*t*p3[1]
        points.append((x, y))
    return points


class Path:
    """Polyline builder in logical units; curves are flattened on the fly."""

    def __init__(self, start):
        self.points = [start]

    def line_to(self, point):
        self.points.append(point)
        return self

    def curve_to(self, c1, c2, point):
        self.points += cubic(self.points[-1], c1, c2, point)
        return self

    def quad_to(self, c, point):
        p0 = self.points[-1]
        c1 = (p0[0] + 2/3*(c[0] - p0[0]), p0[1] + 2/3*(c[1] - p0[1]))
        c2 = (point[0] + 2/3*(c[0] - point[0]), point[1] + 2/3*(c[1] - point[1]))
        return self.curve_to(c1, c2, point)

    def scaled(self, k=1.0, origin=(512, 512)):
        return [(((x - origin[0]) * k + 512) * SUPERSAMPLE,
                 ((y - origin[1]) * k + 512) * SUPERSAMPLE) for x, y in self.points]

    def mirrored(self):
        flipped = Path(self.points[0])
        flipped.points = [(CANVAS - x, y) for x, y in self.points]
        return flipped


def left_page():
    """Left half of the open book: flat top edge, outer edge bowing into a
    rounded bottom corner, bottom edge sweeping down to the spine."""
    path = Path((500, 366))
    path.curve_to((420, 344), (330, 332), (262, 330))
    path.quad_to((216, 330), (216, 376))
    path.line_to((216, 626))
    path.quad_to((216, 668), (258, 674))
    path.curve_to((330, 682), (420, 694), (500, 714))
    path.line_to((500, 366))
    return path


def left_stack():
    """Thin page stack sitting under the left page, split from it by a sliver of
    ground colour."""
    path = Path((228, 692))
    path.curve_to((320, 700), (414, 714), (500, 736))
    path.curve_to((414, 760), (320, 748), (232, 740))
    path.quad_to((220, 738), (220, 726))
    path.line_to((220, 704))
    path.quad_to((220, 692), (228, 692))
    return path


# Bounding box of the mark, and the scale that fits its corners inside the 66dp
# safe circle of a 108dp adaptive canvas (radius 66/108/2 * 1024 = 312 units).
MARK_CENTRE = (512, 545)
FOREGROUND_SCALE = 0.80

RES_TARGETS = {
    "mipmap-mdpi": ("ic_launcher.png", 48),
    "mipmap-hdpi": ("ic_launcher.png", 72),
    "mipmap-xhdpi": ("ic_launcher.png", 96),
    "mipmap-xxhdpi": ("ic_launcher.png", 144),
    "mipmap-xxxhdpi": ("ic_launcher.png", 192),
}


def render():
    """Opaque square master; the design file and every mipmap come from this."""
    image = Image.new("RGB", (CANVAS * SUPERSAMPLE, CANVAS * SUPERSAMPLE), GROUND)
    draw = ImageDraw.Draw(image)
    for shape in (left_page(), left_stack()):
        draw.polygon(shape.scaled(), fill=PAGE)
        draw.polygon(shape.mirrored().scaled(), fill=PAGE)
    return image


def render_foreground():
    """Adaptive-icon foreground: mark only, transparent ground, pulled into the
    66dp safe circle."""
    image = Image.new("RGBA", (CANVAS * SUPERSAMPLE, CANVAS * SUPERSAMPLE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    for shape in (left_page(), left_stack()):
        draw.polygon(shape.scaled(FOREGROUND_SCALE, MARK_CENTRE), fill=PAGE)
        draw.polygon(shape.mirrored().scaled(FOREGROUND_SCALE, MARK_CENTRE), fill=PAGE)
    return image


def export(source, path, size):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    source.resize((size, size), Image.LANCZOS).save(path)
    print(f"wrote {path} ({size}px)")


def main():
    install = "--install" in sys.argv
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    project_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    master_path = args[0] if args else os.path.join(project_root, "design", "readvibe-icon.png")

    source = render()
    export(source, master_path, CANVAS)
    if not install:
        return
    res_root = os.path.join(project_root, "android", "app", "src", "main", "res")
    for folder, (filename, size) in RES_TARGETS.items():
        export(source, os.path.join(res_root, folder, filename), size)
    export(render_foreground(),
           os.path.join(res_root, "drawable-nodpi", "readvibe_mark.png"), 512)


if __name__ == "__main__":
    main()
