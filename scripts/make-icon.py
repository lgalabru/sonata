#!/usr/bin/env python3
"""Builds Resources/AppIcon.icon, the app icon in Icon Composer's format, from the note glyph
(Resources/Icon/glyph.png). scripts/bundle.sh compiles it with actool into the asset catalog
macOS 26 draws icons from (and an .icns for older systems), so the system draws the tile and
the icon isn't put on a grey one. Also writes Resources/Icon/AppIcon-1024.png, a preview on a
dark tile.

The small source is upscaled with premultiplied alpha (no dark fringes) and its edge
re-sharpened, so the outline stays crisp at 1024 px.

Usage: python3 scripts/make-icon.py [glyph.png]   (needs Pillow)
"""
import math, os, shutil, sys
from PIL import Image, ImageChops, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "Resources/Icon/glyph.png")
ICON = os.path.join(ROOT, "Resources/AppIcon.icon")
PREVIEW = os.path.join(ROOT, "Resources/Icon/AppIcon-1024.png")

CANVAS, BODY = 1024, 824          # Apple's macOS icon grid
GLYPH = 600                       # the note's larger side on the tile
SS = 4                            # supersampling for the tile's edge


def squircle_mask(size, body, n=5.0):
    big = size * SS
    m = Image.new("L", (big, big), 0)
    r = body * SS / 2
    c = big / 2
    pts = []
    for k in range(2048):
        t = 2 * math.pi * k / 2048
        ct, st = math.cos(t), math.sin(t)
        x = c + r * math.copysign(abs(ct) ** (2 / n), ct)
        y = c + r * math.copysign(abs(st) ** (2 / n), st)
        pts.append((x, y))
    ImageDraw.Draw(m).polygon(pts, fill=255)
    return m.resize((size, size), Image.LANCZOS)


def vertical_gradient(size, top, bottom):
    g = Image.new("RGB", (1, size))
    for y in range(size):
        f = y / (size - 1)
        g.putpixel((0, y), tuple(round(a + (b - a) * f) for a, b in zip(top, bottom)))
    return g.resize((size, size))


def upscale_glyph(path, target):
    src = Image.open(path).convert("RGBA")
    src = src.crop(src.getbbox())
    scale = target / max(src.size)
    size = (round(src.width * scale), round(src.height * scale))
    # Premultiply, resample, unpremultiply: colour never bleeds in from transparent pixels.
    r, g, b, a = src.split()
    pr, pg, pb = (ImageChops.multiply(ch, a) for ch in (r, g, b))
    big = [ch.resize(size, Image.LANCZOS) for ch in (pr, pg, pb, a)]
    alpha = big[3]
    out = Image.new("RGBA", size)
    ap, cp = alpha.load(), [ch.load() for ch in big[:3]]
    op = out.load()
    for y in range(size[1]):
        for x in range(size[0]):
            av = ap[x, y]
            if av == 0:
                continue
            rgb = tuple(min(255, round(cp[i][x, y] * 255 / av)) for i in range(3))
            # Re-sharpen the edge: a smoothstep around half coverage.
            t = min(1, max(0, (av / 255 - 0.3) / 0.4))
            op[x, y] = rgb + (round(255 * t * t * (3 - 2 * t)),)
    return out


def icon_1024():
    mask = squircle_mask(CANVAS, BODY)
    tile = vertical_gradient(CANVAS, (44, 46, 58), (14, 15, 21)).convert("RGBA")
    # A faint light from above, like the system's icons.
    sheen = Image.new("L", (CANVAS, CANVAS), 0)
    ImageDraw.Draw(sheen).ellipse((-200, -720, CANVAS + 200, 430), fill=34)
    tile = Image.composite(Image.new("RGBA", tile.size, (255, 255, 255, 255)), tile, sheen.filter(ImageFilter.GaussianBlur(120)))
    icon = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    icon.paste(tile, (0, 0), mask)
    # A hairline edge so the tile holds on dark docks.
    edge = ImageChops.subtract(mask, squircle_mask(CANVAS, BODY - 4))
    icon = Image.alpha_composite(icon, Image.merge("RGBA", (*[Image.new("L", icon.size, 255)] * 3, edge.point(lambda v: v * 0.10))))

    glyph = upscale_glyph(SRC, GLYPH)
    gx, gy = (CANVAS - glyph.width) // 2 + 8, (CANVAS - glyph.height) // 2 - 6
    shadow = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 120), (gx, gy + 22), glyph.getchannel("A"))
    icon = Image.alpha_composite(icon, shadow.filter(ImageFilter.GaussianBlur(28)))
    layer = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    layer.paste(glyph, (gx, gy), glyph)
    return Image.alpha_composite(icon, layer)


ICON_JSON = """{
  "fill-specializations": [
    { "value": { "solid": "srgb:0.98000,0.97500,0.99000,1.00000" } },
    { "appearance": "dark", "value": { "solid": "srgb:0.08627,0.09020,0.11765,1.00000" } }
  ],
  "groups": [
    {
      "layers": [
        { "glass": false, "image-name": "note.png", "name": "note" }
      ],
      "shadow": { "kind": "neutral", "opacity": 0.5 },
      "specular": true,
      "translucency": { "enabled": false, "value": 0 }
    }
  ],
  "supported-platforms": { "squares": ["macOS"] }
}
"""


def main():
    # The note alone on a transparent 1024 canvas: the system supplies the tile.
    glyph = upscale_glyph(SRC, GLYPH)
    note = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    note.paste(glyph, ((CANVAS - glyph.width) // 2 + 8, (CANVAS - glyph.height) // 2 - 6), glyph)
    shutil.rmtree(ICON, ignore_errors=True)
    os.makedirs(os.path.join(ICON, "Assets"))
    note.save(os.path.join(ICON, "Assets", "note.png"))
    with open(os.path.join(ICON, "icon.json"), "w") as f:
        f.write(ICON_JSON)
    icon_1024().save(PREVIEW)
    print(f"wrote {ICON} and {PREVIEW}")


if __name__ == "__main__":
    main()
