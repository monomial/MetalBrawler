#!/usr/bin/env python3
"""Generate MetalBrawler app icons for iOS, macOS, and tvOS."""

import math
import os
from PIL import Image, ImageDraw, ImageFilter

OUT = os.path.join(os.path.dirname(__file__), "..", "icon_output")
os.makedirs(OUT, exist_ok=True)


def make_bg(img: Image.Image) -> None:
    """Fill with a radial charcoal→dark-purple gradient."""
    w, h = img.size
    draw = ImageDraw.Draw(img)
    cx, cy = w / 2, h / 2
    max_r = math.hypot(cx, cy)
    center_color = (26, 26, 46)   # #1A1A2E charcoal-navy
    edge_color   = (10, 8, 20)    # #0A0814 near-black purple
    for y in range(h):
        for x in range(w):
            r = math.hypot(x - cx, y - cy) / max_r
            r = min(r, 1.0)
            col = tuple(int(center_color[i] + (edge_color[i] - center_color[i]) * r) for i in range(3))
            draw.point((x, y), fill=col)


def bolt_polygon(w: int, h: int, x_scale: float = 1.0) -> list[tuple[float, float]]:
    """
    Classic lightning bolt polygon, centered in w×h.
    x_scale > 1 stretches it horizontally for landscape canvases.
    """
    # Design in unit coords [-0.5, 0.5] x [-0.5, 0.5], then map to pixels.
    # Bolt fills ~65% of the shorter dimension.
    size = min(w, h) * 0.65
    pts_unit = [
        ( 0.12,  0.50),   # top-right of upper blade
        (-0.22,  0.50),   # top-left  of upper blade
        (-0.04,  0.02),   # inner notch (going down-right)
        (-0.28, -0.00),   # left notch tip
        (-0.12, -0.50),   # bottom-left of lower blade
        ( 0.22, -0.50),   # bottom-right of lower blade
        ( 0.05, -0.02),   # inner notch (going up-left)
        ( 0.30,  0.01),   # right notch tip
    ]
    cx, cy = w / 2, h / 2
    # Apply x_scale to spread bolt wider on landscape canvas
    return [
        (cx + p[0] * size * x_scale, cy - p[1] * size)
        for p in pts_unit
    ]


def gradient_bolt(draw: ImageDraw.Draw, pts: list, w: int, h: int) -> None:
    """Draw bolt with a vertical blue→silver gradient via scanline masking."""
    from PIL import Image as PILImage

    # Bounding box of bolt
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    y_min, y_max = min(ys), max(ys)

    # Build gradient overlay
    grad = PILImage.new("RGBA", (w, h), (0, 0, 0, 0))
    for y in range(int(y_min), int(y_max) + 1):
        t = (y - y_min) / max(y_max - y_min, 1)
        # electric blue (#4FC3F7) → silver (#C8C8D0)
        r = int(79  + (200 - 79)  * t)
        g = int(195 + (200 - 195) * t)
        b = int(247 + (208 - 247) * t)
        grad.putpixel((0, y), (r, g, b, 255))  # placeholder; we'll use it per-row

    # Draw bolt in solid blue first, then we'll tint
    # Actually, draw row-by-row isn't practical with PIL polygon; use two-pass approach:
    # Pass 1: draw solid bolt into a mask image
    mask = PILImage.new("L", (w, h), 0)
    mask_draw = ImageDraw.Draw(mask)
    mask_draw.polygon(pts, fill=255)

    # Pass 2: draw gradient into the bolt shape using the mask
    gradient = PILImage.new("RGBA", (w, h), (0, 0, 0, 0))
    gd = ImageDraw.Draw(gradient)
    for y in range(int(y_min), int(y_max) + 1):
        t = (y - y_min) / max(y_max - y_min, 1)
        r = int(79  + (200 - 79)  * t)
        g = int(195 + (200 - 195) * t)
        b = int(247 + (208 - 247) * t)
        gd.line([(0, y), (w, y)], fill=(r, g, b, 255))

    gradient.putalpha(mask)
    return gradient, mask


def draw_icon(w: int, h: int, x_scale: float = 1.0) -> Image.Image:
    img = Image.new("RGBA", (w, h), (0, 0, 0, 255))

    # Background
    make_bg(img)

    pts = bolt_polygon(w, h, x_scale)

    # Shadow — dark blue offset
    shadow_off = int(min(w, h) * 0.04)
    shadow_pts = [(x + shadow_off, y + shadow_off) for x, y in pts]
    shadow_layer = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow_layer)
    shadow_draw.polygon(shadow_pts, fill=(10, 20, 60, 180))
    shadow_layer = shadow_layer.filter(ImageFilter.GaussianBlur(radius=shadow_off * 0.8))
    img = Image.alpha_composite(img.convert("RGBA"), shadow_layer)

    # Gradient bolt
    gradient, mask = gradient_bolt(None, pts, w, h)
    img = Image.alpha_composite(img, gradient)

    # White highlight on upper portion of bolt
    highlight = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    hl_draw = ImageDraw.Draw(highlight)
    ys = [p[1] for p in pts]
    cy = (min(ys) + max(ys)) / 2
    hl_pts = [(x, y) for x, y in pts if y < cy + (max(ys) - min(ys)) * 0.15]
    if len(hl_pts) >= 3:
        hl_draw.polygon(hl_pts, fill=(255, 255, 255, 55))
    img = Image.alpha_composite(img, highlight)

    # Thin bright-white outline on bolt for crispness
    outline_layer = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    ol_draw = ImageDraw.Draw(outline_layer)
    lw = max(1, int(min(w, h) * 0.008))
    ol_draw.polygon(pts, outline=(220, 240, 255, 180), width=lw)
    img = Image.alpha_composite(img, outline_layer)

    return img.convert("RGB")


def save(img: Image.Image, name: str) -> None:
    path = os.path.join(OUT, name)
    img.save(path, "PNG")
    print(f"  wrote {name}  ({img.width}×{img.height})")


def square(size: int) -> Image.Image:
    return draw_icon(size, size, x_scale=1.0)


def landscape(w: int, h: int) -> Image.Image:
    # x_scale spreads the bolt to fill the wider canvas
    return draw_icon(w, h, x_scale=max(1.0, (w / h) * 0.75))


if __name__ == "__main__":
    print("Generating square icons (iOS / macOS)…")
    for size in [16, 32, 64, 128, 256, 512, 1024]:
        save(square(size), f"icon_{size}.png")

    print("\nGenerating tvOS icons…")
    save(landscape(400,  240),  "icon_tv_400x240.png")
    save(landscape(800,  480),  "icon_tv_800x480.png")
    save(landscape(1280, 768),  "icon_tv_1280x768.png")
    save(landscape(2560, 1536), "icon_tv_2560x1536.png")
    save(landscape(2320, 720),  "icon_tv_topshelf_2320x720.png")
    save(landscape(1920, 720),  "icon_tv_topshelf_1920x720.png")

    print(f"\nDone — all files in {os.path.abspath(OUT)}/")
