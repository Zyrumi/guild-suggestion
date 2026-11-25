# Draws the GuildSuggestion project icon in code (CurseForge doesn't allow
# Blizzard art): a parchment letter with a red wax seal on a dark blue tile.
# Writes art/curseforge-icon.png (512 x 512) and a 64 x 64 preview.
# Run: python -I tools/make_icon.py
import os
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
ART = os.path.join(HERE, "..", "art")

SIZE = 512
S = 4  # drawn 4x larger, then scaled down for smooth edges
BLUE = ((40, 62, 110), (12, 18, 38))        # tile: middle, edges
PAPER = (236, 220, 180)
PAPER_DARK = (196, 172, 120)
INK = (110, 84, 50)
WAX = (168, 30, 36)
WAX_DARK = (110, 14, 20)
GOLD = (240, 200, 90)


def mix(a, b, t):
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))


def main():
    n = SIZE * S
    tile = Image.new("RGB", (SIZE, SIZE))
    px = tile.load()
    c = (SIZE - 1) / 2
    far = (2 * c * c) ** 0.5
    for y in range(SIZE):
        for x in range(SIZE):
            px[x, y] = mix(*BLUE, min(1.0, (((x - c) ** 2 + (y - c) ** 2) ** 0.5) / far))
    tile = tile.resize((n, n))

    layer = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    # Letter (envelope) body.
    l, t, r, b = 0.14 * n, 0.27 * n, 0.86 * n, 0.75 * n
    shadow = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle((l + 0.015 * n, t + 0.025 * n, r + 0.015 * n, b + 0.025 * n),
                                             radius=0.03 * n, fill=(0, 0, 0, 140))
    layer = Image.alpha_composite(layer, shadow.filter(ImageFilter.GaussianBlur(0.02 * n)))
    d = ImageDraw.Draw(layer)
    d.rounded_rectangle((l, t, r, b), radius=0.03 * n, fill=PAPER, outline=PAPER_DARK, width=round(0.008 * n))
    mid = (l + r) / 2
    # Bottom folds and the flap.
    w = round(0.007 * n)
    d.line((l, b, mid, t + 0.30 * n), fill=PAPER_DARK, width=w)
    d.line((r, b, mid, t + 0.30 * n), fill=PAPER_DARK, width=w)
    d.polygon((l, t, r, t, mid, t + 0.27 * n), fill=mix(PAPER, PAPER_DARK, 0.35), outline=PAPER_DARK)
    # A written sheet sticking out of the envelope.
    sheet = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    ImageDraw.Draw(sheet).rounded_rectangle((l + 0.07 * n, t - 0.13 * n, r - 0.07 * n, t + 0.05 * n),
                                            radius=0.02 * n, fill=PAPER, outline=PAPER_DARK, width=w)
    sd = ImageDraw.Draw(sheet)
    for i, frac in enumerate((0.55, 0.45)):
        y = t - 0.085 * n + i * 0.05 * n
        half = (r - l - 0.14 * n) * frac / 2
        sd.line((mid - half, y, mid + half, y), fill=INK, width=round(0.012 * n))
    under = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    under = Image.alpha_composite(under, sheet)
    layer = Image.alpha_composite(under, layer)
    d = ImageDraw.Draw(layer)
    # Wax seal on the flap's point, with a gold plus (a suggestion to add someone).
    cy = t + 0.27 * n
    rad = 0.105 * n
    d.ellipse((mid - rad * 1.08, cy - rad * 1.08, mid + rad * 1.08, cy + rad * 1.08), fill=WAX_DARK)
    d.ellipse((mid - rad, cy - rad, mid + rad, cy + rad), fill=WAX)
    arm, thick = 0.055 * n, 0.024 * n
    d.rounded_rectangle((mid - arm, cy - thick / 2, mid + arm, cy + thick / 2), radius=thick / 2, fill=GOLD)
    d.rounded_rectangle((mid - thick / 2, cy - arm, mid + thick / 2, cy + arm), radius=thick / 2, fill=GOLD)

    out = Image.alpha_composite(tile.convert("RGBA"), layer)
    out = out.resize((SIZE, SIZE), Image.LANCZOS).convert("RGB")
    os.makedirs(ART, exist_ok=True)
    out.save(os.path.join(ART, "curseforge-icon.png"))
    out.resize((64, 64), Image.LANCZOS).save(os.path.join(ART, "curseforge-icon-64.png"))
    print("wrote art/curseforge-icon.png and art/curseforge-icon-64.png")


if __name__ == "__main__":
    main()
