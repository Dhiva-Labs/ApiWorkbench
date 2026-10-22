"""Generates the two Google Play store graphics for ApiWorkbench.

    store/graphics/icon-512.png                 Play hi-res icon
    store/graphics/feature-graphic-1024x500.png Play feature graphic

Both are rebuilt from the repo's own assets and palette, so they can be
regenerated at any time with:

    python3 -I store/scripts/make_store_graphics.py

Requires Pillow (tested with Pillow 12) and the system fonts listed in
``SANS_BOLD`` / ``SANS_REGULAR`` / ``MONO_BOLD`` below (first match wins).

Hi-res icon (Play requires 512 x 512, 32-bit PNG, no transparency):
  * Starts from the shipping logo ``assets/icon/apiworkbench_512.png``
    (RGBA, rounded tile on transparent corners — the same bitmap that ships
    as ``android/app/src/main/res/mipmap-*/ic_launcher.png``).
  * Flattens it onto the logo's own colours — ``LogoPainter.teal`` above
    and ``LogoPainter.tealDeep`` for the bottom band (``lib/ui/logo.dart``
    draws the band from y = 86 of the 120-unit design space) — so the
    transparent corners fill in seamlessly and the result equals the
    ``LogoShape.square`` variant: full-bleed, no baked-in rounded corners,
    no shadow. Play masks the shape itself.
  * Saved as opaque RGB, so there is no alpha channel to flatten/reject.

Feature graphic (Play requires exactly 1024 x 500, JPG or 24-bit PNG):
  * The app's default Teal theme (``PaletteData.tealDark`` in
    ``lib/theme.dart``) for the background, text and accents; the logo tile
    itself is the real shipping bitmap, not a redrawn approximation.
  * App name + one factual tagline; the HTTP method names underneath are set
    in the palette's own per-method colours (``PaletteData.get_`` ...) as a
    typographic motif — plain coloured words, no chips, no fake UI chrome,
    no screenshots, no device frames, no claims or calls to action.
  * The lower-left region is background only, because Play overlays the app
    icon + title chip there when the graphic is used as a promo card.
  * Rendered at 2x and LANCZOS-downsampled so text and edges stay crisp;
    the logo tile is composited at final resolution straight from the 512px
    source so it is only ever downscaled.
"""

from __future__ import annotations

import random
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

REPO = Path(__file__).resolve().parent.parent.parent
LOGO_SRC = REPO / "assets" / "icon" / "apiworkbench_512.png"
OUT_DIR = REPO / "store" / "graphics"
ICON_OUT = OUT_DIR / "icon-512.png"
FEATURE_OUT = OUT_DIR / "feature-graphic-1024x500.png"

ICON_SIZE = 512
FEATURE_W, FEATURE_H = 1024, 500
SUPERSAMPLE = 2

# --- Palette -------------------------------------------------------------
# lib/ui/logo.dart LogoPainter
LOGO_TEAL = (14, 140, 140)  # LogoPainter.teal      0xFF0E8C8C (== tealLight.accent)
LOGO_TEAL_DEEP = (11, 118, 118)  # LogoPainter.tealDeep  0xFF0B7676
LOGO_BAND_TOP = 86 / 120  # Rect.fromLTWH(0, 86, 120, 34) in a 120-unit canvas

# lib/theme.dart PaletteData.tealDark (the default "Teal" theme, dark mode)
BG = (18, 22, 28)  # bg          0xFF12161C
SURFACE = (26, 32, 40)  # surface     0xFF1A2028
SURFACE_ALT = (34, 42, 52)  # surfaceAlt  0xFF222A34
BORDER = (42, 50, 61)  # border      0xFF2A323D
ACCENT = (60, 195, 195)  # accent      0xFF3CC3C3
ACCENT_SOFT = (23, 58, 61)  # accentSoft  0xFF173A3D
TEXT = (231, 236, 242)  # text        0xFFE7ECF2
TEXT_DIM = (141, 153, 168)  # textDim     0xFF8D99A8
METHOD_COLOURS = {  # get_ / post / put / patch / delete / query
    "GET": (76, 195, 138),  # 0xFF4CC38A
    "POST": (232, 176, 75),  # 0xFFE8B04B
    "PUT": (94, 162, 240),  # 0xFF5EA2F0
    "PATCH": (180, 140, 242),  # 0xFFB48CF2
    "DELETE": (239, 106, 106),  # 0xFFEF6A6A
    "QUERY": (85, 198, 216),  # 0xFF55C6D8
}

# --- Fonts ---------------------------------------------------------------
# The app bundles no fonts (it uses the platform sans — Roboto on Android —
# and the generic 'monospace' family for code), so use the closest clean
# system faces. Each list is tried in order; the first file that exists wins.
SANS_BOLD = [
    "/usr/share/fonts/truetype/noto/NotoSans-Bold.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
]
SANS_REGULAR = [
    "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
]
MONO_BOLD = [
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationMono-Bold.ttf",
    "/usr/share/fonts/truetype/noto/NotoMono-Regular.ttf",
]

TITLE = "ApiWorkbench"
TAGLINE = "API client for REST, GraphQL and load testing"


def _font(candidates: list[str], size: int) -> ImageFont.FreeTypeFont:
    for path in candidates:
        if Path(path).is_file():
            return ImageFont.truetype(path, size)
    raise SystemExit(f"none of these fonts exist: {candidates}")


def _lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


# =========================================================================
# Hi-res icon
# =========================================================================


def load_logo() -> Image.Image:
    with Image.open(LOGO_SRC) as src:
        src.load()
        logo = src.convert("RGBA")
    if logo.size[0] != logo.size[1]:
        raise SystemExit(f"{LOGO_SRC} is not square: {logo.size}")
    return logo


def build_icon(logo: Image.Image) -> Image.Image:
    """Flatten the rounded RGBA logo onto its own teal/deep-teal backdrop.

    The backdrop reproduces what LogoPainter paints *under* the glyphs
    (teal, with the deep band from LOGO_BAND_TOP down), so the transparent
    rounded corners fill in with exactly the colour the tile would have had
    if drawn with LogoShape.square. Anti-aliased edge pixels blend into the
    same colour, so there is no visible seam.
    """
    size = logo.size[0]
    backdrop = Image.new("RGBA", (size, size), (*LOGO_TEAL, 255))
    band_top = round(size * LOGO_BAND_TOP)
    ImageDraw.Draw(backdrop).rectangle(
        [0, band_top, size, size], fill=(*LOGO_TEAL_DEEP, 255)
    )
    flat = Image.alpha_composite(backdrop, logo).convert("RGB")
    if flat.size != (ICON_SIZE, ICON_SIZE):
        flat = flat.resize((ICON_SIZE, ICON_SIZE), Image.LANCZOS)
    return flat


# =========================================================================
# Feature graphic
# =========================================================================


def _background(w: int, h: int) -> Image.Image:
    """Diagonal gradient between the theme's canvas and panel colours.

    The two colours are only ~8-12 levels apart per channel, so a plain
    8-bit lerp bands visibly; a seeded +/-1 dither hides that as fine grain
    without shifting the average colour, and stays identical across reruns.
    """
    rng = random.Random(20261022)
    img = Image.new("RGB", (w, h), BG)
    px = img.load()
    for y in range(h):
        ty = y / h
        left = _lerp(BG, SURFACE, ty * 0.55)
        right = _lerp(SURFACE, SURFACE_ALT, ty * 0.35)
        for x in range(w):
            r, g, b = _lerp(left, right, x / w)
            n = rng.randint(-1, 1)
            px[x, y] = (
                min(255, max(0, r + n)),
                min(255, max(0, g + n)),
                min(255, max(0, b + n)),
            )
    return img


def _dot_grid(w: int, h: int, s: int, x_from: int) -> Image.Image:
    """A faint dot grid on the right part of the canvas — a 'workbench'
    texture that stays out of the text column and the lower-left overlay
    zone, and is far too subtle to read as UI."""
    layer = Image.new("RGBA", (w, h), (*BORDER, 0))
    draw = ImageDraw.Draw(layer)
    step = 32 * s
    r = max(1, round(1.4 * s))
    for y in range(step // 2, h, step):
        for x in range(x_from + step // 2, w, step):
            draw.ellipse([x - r, y - r, x + r, y + r], fill=(*BORDER, 190))
    return layer


def _glow(w: int, h: int, centre, radius: int) -> Image.Image:
    """Soft accent-coloured halo behind the logo tile.

    The layer's RGB is the accent everywhere and only the alpha is shaped,
    so the blur does not bleed black into the colour.
    """
    layer = Image.new("RGBA", (w, h), (*ACCENT, 0))
    draw = ImageDraw.Draw(layer)
    cx, cy = centre
    draw.ellipse(
        [cx - radius, cy - radius * 0.86, cx + radius, cy + radius * 0.86],
        fill=(*ACCENT, 60),
    )
    return layer.filter(ImageFilter.GaussianBlur(radius * 0.55))


def build_feature_graphic(logo: Image.Image) -> Image.Image:
    s = SUPERSAMPLE
    w, h = FEATURE_W * s, FEATURE_H * s

    # Layout (in final pixels, scaled by `s` when drawn).
    margin_x = 64
    tile = 264
    tile_x = FEATURE_W - 72 - tile
    tile_y = (FEATURE_H - tile) // 2
    tile_cx, tile_cy = tile_x + tile // 2, tile_y + tile // 2

    base = _background(w, h).convert("RGBA")
    base = Image.alpha_composite(base, _dot_grid(w, h, s, x_from=int(w * 0.46)))
    base = Image.alpha_composite(
        base, _glow(w, h, (tile_cx * s, tile_cy * s), int(tile * 0.95 * s))
    )

    draw = ImageDraw.Draw(base)
    title_font = _font(SANS_BOLD, 76 * s)
    tagline_font = _font(SANS_REGULAR, 26 * s)
    method_font = _font(MONO_BOLD, 18 * s)

    x = margin_x * s
    # Baselines; the block sits a touch above centre so the lower-left stays
    # clear for Play's icon/title overlay.
    title_base = 196 * s
    tagline_base = 251 * s
    method_base = 306 * s

    draw.text((x, title_base), TITLE, font=title_font, fill=TEXT, anchor="ls")
    draw.text(
        (x, tagline_base), TAGLINE, font=tagline_font, fill=ACCENT, anchor="ls"
    )

    # Method names in the theme's per-method colours, as plain words.
    cursor = x
    gap = draw.textlength("  ", font=method_font)
    for i, (name, colour) in enumerate(METHOD_COLOURS.items()):
        if i:
            draw.text(
                (cursor, method_base), "·", font=method_font, fill=TEXT_DIM, anchor="ls"
            )
            cursor += draw.textlength("·", font=method_font) + gap
        draw.text((cursor, method_base), name, font=method_font, fill=colour, anchor="ls")
        cursor += draw.textlength(name, font=method_font) + gap

    # Guard: the text column must not run into the tile.
    title_w = draw.textlength(TITLE, font=title_font)
    text_right = max(title_w + x, draw.textlength(TAGLINE, font=tagline_font) + x, cursor)
    assert text_right < tile_x * s - 24 * s, (text_right / s, tile_x)

    final = base.resize((FEATURE_W, FEATURE_H), Image.LANCZOS)

    # Logo tile at final resolution, downscaled once from the 512px source.
    tile_img = logo.resize((tile, tile), Image.LANCZOS)
    final.alpha_composite(tile_img, (tile_x, tile_y))
    return final.convert("RGB")


# =========================================================================


def _save_and_verify(img: Image.Image, path: Path, size: tuple[int, int]) -> None:
    if img.mode != "RGB":
        img = img.convert("RGB")
    path.parent.mkdir(parents=True, exist_ok=True)
    img.save(path, format="PNG", optimize=True)
    # Check what actually landed on disk, not the in-memory object.
    with Image.open(path) as check:
        check.load()
        assert check.format == "PNG", check.format
        assert check.size == size, check.size
        assert check.mode == "RGB", check.mode
        assert "A" not in check.getbands(), check.getbands()
        assert "transparency" not in check.info, check.info
    print(
        f"wrote {path.relative_to(REPO)} "
        f"({size[0]}x{size[1]}, mode=RGB, {path.stat().st_size:,} bytes)"
    )


def main() -> None:
    logo = load_logo()
    _save_and_verify(build_icon(logo), ICON_OUT, (ICON_SIZE, ICON_SIZE))
    _save_and_verify(
        build_feature_graphic(logo), FEATURE_OUT, (FEATURE_W, FEATURE_H)
    )


if __name__ == "__main__":
    main()
