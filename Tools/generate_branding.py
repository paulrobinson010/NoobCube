#!/usr/bin/env python3
"""Build every branded asset from the one piece of artwork.

The master icon lives in `Branding/appIcon-source.png`. Everything the app
shows — the app icon, the launch screen logo, the little cube mark in each
screen header, and the wordmark — is cut from it here, so replacing the
artwork and re-running this is all it takes to re-brand the app.

    python3 Tools/generate_branding.py

Needs Pillow:  pip3 install Pillow
"""
import json
import os
import sys

try:
    from PIL import Image, ImageDraw, ImageFilter, ImageFont
except ImportError:
    sys.exit("This needs Pillow: pip3 install Pillow")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(ROOT, 'Branding', 'appIcon-source.png')
ASSETS = os.path.join(ROOT, 'NoobCube', 'Assets.xcassets')

# Regions measured from the artwork. If the icon is redrawn these are the
# numbers to revisit; they are fractions so they survive a change of size.
CUBE_CENTRE = (0.4944, 0.3732)   # middle of the cube, as a fraction of the image
CUBE_HALF = 0.3620               # half-width of the crop, leaving the glow in
WORDMARK_BOX = (0.0829, 0.7528, 0.9218, 0.8916)   # left, top, right, bottom

# Theme.background, so the launch screen and the first real screen match.
LAUNCH_BACKGROUND = (18, 23, 41)

INFO = {'author': 'xcode', 'version': 1}


def write_json(folder, payload):
    os.makedirs(folder, exist_ok=True)
    with open(os.path.join(folder, 'Contents.json'), 'w') as handle:
        json.dump(payload, handle, indent=2)
        handle.write('\n')


def clear_pngs(folder):
    """Make sure the folder exists and holds no stale images."""
    os.makedirs(folder, exist_ok=True)
    for name in os.listdir(folder):
        if name.endswith('.png'):
            os.remove(os.path.join(folder, name))


def crop_fraction(image, box):
    width, height = image.size
    left, top, right, bottom = box
    return image.crop((int(left * width), int(top * height),
                       int(right * width), int(bottom * height)))


# ---------------------------------------------------------------- app icon

def build_app_icon(source):
    folder = os.path.join(ASSETS, 'AppIcon.appiconset')
    clear_pngs(folder)
    # App Store icons must be square, 1024, and carry no alpha channel.
    icon = source.convert('RGB').resize((1024, 1024), Image.LANCZOS)
    icon.save(os.path.join(folder, 'AppIcon-1024.png'))
    write_json(folder, {
        'images': [{
            'filename': 'AppIcon-1024.png',
            'idiom': 'universal',
            'platform': 'ios',
            'size': '1024x1024',
        }],
        'info': INFO,
    })
    print('  AppIcon            1024x1024')


# ------------------------------------------------------------ launch screen

# How much of the tile's edge is given over to fading out, as a fraction of
# its width. The artwork is vignette out to about 6% in — the brightest pixel
# anywhere in that band is 96 of 255, and nothing hits full brightness until
# 7.8% in — so a fade this wide dissolves the edge without touching the cube,
# the wordmark or either glow.
LAUNCH_FADE = 0.06


def build_launch_logo(source):
    """The icon artwork as a rounded tile that fades out at its edge.

    A hard-edged tile cannot be made to disappear into a flat colour, because
    the artwork's own background is not flat: it is a vignette, running from
    (3, 21, 56) at the top of the icon to (1, 6, 17) at the bottom. Whatever one
    colour the screen is painted, one edge of the tile shows. Measured against
    the colour the screen actually uses, the bottom edge was out by 12 and the
    top by 44, and the bottom is where it reads as a seam rather than a glow.

    So the tile stops having an edge. The outer band fades to nothing, and the
    icon dissolves into the screen whatever shade the screen happens to be.
    """
    folder = os.path.join(ASSETS, 'LaunchLogo.imageset')
    clear_pngs(folder)

    images = []
    base = 200                                   # points
    for scale in (1, 2, 3):
        side = base * scale
        tile = source.convert('RGBA').resize((side, side), Image.LANCZOS)

        # A rounded rectangle drawn a fade's width in, then blurred by about
        # the same amount: solid through the middle, nothing at all by the
        # time it reaches where the edge used to be.
        fade = side * LAUNCH_FADE
        mask = Image.new('L', (side, side), 0)
        ImageDraw.Draw(mask).rounded_rectangle(
            (fade, fade, side - 1 - fade, side - 1 - fade),
            radius=max(1, int((side - 2 * fade) * 0.225)), fill=255)
        mask = mask.filter(ImageFilter.GaussianBlur(radius=fade * 0.55))
        tile.putalpha(mask)

        name = f'LaunchLogo@{scale}x.png'
        tile.save(os.path.join(folder, name))
        images.append({'filename': name, 'idiom': 'universal', 'scale': f'{scale}x'})

    write_json(folder, {'images': images, 'info': INFO})
    print(f'  LaunchLogo         {base}pt tile, edge faded over {LAUNCH_FADE:.0%}')


def edge_colour(source):
    """The colour right at the edge of the artwork.

    The app and the launch screen both paint themselves this, so the icon
    dissolves into the screen behind it instead of sitting on a lighter panel.
    Measured from the outermost pixels rather than typed in, so it follows the
    artwork if that is ever redrawn.
    """
    image = source.convert('RGB')
    width, height = image.size
    pixels = image.load()
    ring = []
    for depth in range(8):
        for x in range(width):
            ring.append(pixels[x, depth])
            ring.append(pixels[x, height - 1 - depth])
        for y in range(height):
            ring.append(pixels[depth, y])
            ring.append(pixels[width - 1 - depth, y])
    # Median, not mean: a bright corner glow should not drag the whole screen up.
    return tuple(sorted(channel[index] for channel in ring)[len(ring) // 2]
                 for index in range(3))


def report_launch_background(source):
    """Measure the artwork's edge and say whether the token still matches.

    The colour set itself belongs to `Design/tokens.json` and is written by
    `Tools/sync_design.py`, along with every other copy of the palette. Writing
    it here as well meant two tools owned one file and quietly disagreed: this
    one measures the 1254px master, the token was measured off the 1024px icon
    that actually ships, and resampling put a unit of blue between them.

    So this only looks, and says something if the two have drifted far enough
    to matter.
    """
    red, green, blue = edge_colour(source)
    measured = f'#{red:02x}{green:02x}{blue:02x}'

    token = None
    tokens_path = os.path.join(ROOT, 'Design', 'tokens.json')
    if os.path.exists(tokens_path):
        with open(tokens_path) as handle:
            token = json.load(handle).get('surface', {}).get('background')

    if token is None:
        print(f'  LaunchBackground   {measured} from the artwork edge')
    elif token.lower() == measured:
        print(f'  LaunchBackground   {measured}, and the token agrees')
    else:
        print(f'  LaunchBackground   artwork edge is {measured}, '
              f'Design/tokens.json says {token}')
        print('                     put the new one in tokens.json and run '
              'Tools/sync_design.py if it matters')


# -------------------------------------------------------------- header mark

def build_brand_mark(source):
    """Just the cube, fading out at the edges.

    A hard-edged crop would show its own dark background as a square against
    the app's slightly lighter one. Fading the alpha away instead lets the
    glow sit straight on the screen with no visible box.
    """
    folder = os.path.join(ASSETS, 'BrandMark.imageset')
    clear_pngs(folder)

    width, height = source.size
    centre_x, centre_y = int(CUBE_CENTRE[0] * width), int(CUBE_CENTRE[1] * height)
    half = int(CUBE_HALF * width)
    cube = source.convert('RGBA').crop((centre_x - half, centre_y - half,
                                        centre_x + half, centre_y + half))

    images = []
    base = 44
    for scale in (1, 2, 3):
        side = base * scale
        # Fade at a high resolution, then size down, so the edge stays smooth.
        working = 512
        tile = cube.resize((working, working), Image.LANCZOS)
        mask = Image.new('L', (working, working), 0)
        inset = int(working * 0.025)
        ImageDraw.Draw(mask).ellipse((inset, inset, working - inset, working - inset), fill=255)
        mask = mask.filter(ImageFilter.GaussianBlur(working * 0.10))
        tile.putalpha(mask)
        tile = tile.resize((side, side), Image.LANCZOS)

        name = f'BrandMark@{scale}x.png'
        tile.save(os.path.join(folder, name))
        images.append({'filename': name, 'idiom': 'universal', 'scale': f'{scale}x'})

    write_json(folder, {'images': images, 'info': INFO})
    print(f'  BrandMark          {base}pt, faded edges')


# ----------------------------------------------------------------- wordmark

def _cut_wordmark(source):
    """The NoobCube lettering, lifted off its background.

    The artwork sits on near-black, so brightness doubles as coverage: it gives
    the alpha, and dividing it back out of the colour recovers the real one.
    That keeps the cyan-to-magenta gradient true instead of muddy.
    """
    word = crop_fraction(source.convert('RGB'), WORDMARK_BOX)
    width, height = word.size
    cut = Image.new('RGBA', (width, height))
    source_pixels, cut_pixels = word.load(), cut.load()

    low, high = 26.0, 115.0
    for y in range(height):
        for x in range(width):
            red, green, blue = source_pixels[x, y]
            coverage = (max(red, green, blue) - low) / (high - low)
            coverage = min(1.0, max(0.0, coverage))
            if coverage <= 0.004:
                cut_pixels[x, y] = (0, 0, 0, 0)
            else:
                cut_pixels[x, y] = (min(255, int(red / coverage)),
                                    min(255, int(green / coverage)),
                                    min(255, int(blue / coverage)),
                                    int(coverage * 255))
    return cut


def build_wordmark(source):
    folder = os.path.join(ASSETS, 'BrandWordmark.imageset')
    clear_pngs(folder)
    cut = _cut_wordmark(source)
    width, height = cut.size

    images = []
    base = 180
    for scale in (1, 2, 3):
        target_width = base * scale
        target_height = max(1, round(target_width * height / width))
        name = f'BrandWordmark@{scale}x.png'
        cut.resize((target_width, target_height), Image.LANCZOS).save(
            os.path.join(folder, name))
        images.append({'filename': name, 'idiom': 'universal', 'scale': f'{scale}x'})

    write_json(folder, {'images': images, 'info': INFO})
    print(f'  BrandWordmark      {base}pt wide')


# ---------------------------------------------------------------- the website

DOCS = os.path.join(ROOT, 'docs', 'assets')


def build_web_assets(source):
    """Images for the landing page in docs/, cut from the same artwork."""
    os.makedirs(DOCS, exist_ok=True)

    # Favicon: the whole icon, small and square.
    source.convert('RGB').resize((256, 256), Image.LANCZOS).save(
        os.path.join(DOCS, 'favicon.png'))


    # The cube on its own, edges faded, for the hero and the social card.
    width, height = source.size
    centre_x, centre_y = int(CUBE_CENTRE[0] * width), int(CUBE_CENTRE[1] * height)
    half = int(CUBE_HALF * width)
    cube = source.convert('RGBA').crop((centre_x - half, centre_y - half,
                                        centre_x + half, centre_y + half))
    working = 720
    cube = cube.resize((working, working), Image.LANCZOS)
    mask = Image.new('L', (working, working), 0)
    inset = int(working * 0.025)
    ImageDraw.Draw(mask).ellipse((inset, inset, working - inset, working - inset), fill=255)
    cube.putalpha(mask.filter(ImageFilter.GaussianBlur(working * 0.10)))
    cube.save(os.path.join(DOCS, 'logo.png'))

    # The lettering on its own, for the page heading.
    word = _cut_wordmark(source)
    word_width = 900
    word_height = round(word_width * word.size[1] / word.size[0])
    word.resize((word_width, word_height), Image.LANCZOS).save(
        os.path.join(DOCS, 'brand.png'))

    _build_social_card(cube, word)
    print('  docs/assets       favicon, logo, brand, og')


def _build_social_card(cube, word):
    """The 1200x630 picture that shows up when the link is shared."""
    card_width, card_height = 1200, 630
    card = Image.new('RGB', (card_width, card_height), (4, 7, 15))

    # A soft glow behind the middle, the same shape as the icon's.
    glow = Image.new('RGB', (card_width, card_height), (4, 7, 15))
    draw = ImageDraw.Draw(glow)
    draw.ellipse((-140, -260, 700, 520), fill=(10, 42, 70))
    draw.ellipse((640, -200, 1420, 560), fill=(46, 10, 74))
    card = Image.blend(card, glow.filter(ImageFilter.GaussianBlur(150)), 0.85)

    art = cube.resize((400, 400), Image.LANCZOS)
    card.paste(art, (70, 115), art)

    lettering_width = 600
    lettering_height = round(lettering_width * word.size[1] / word.size[0])
    lettering = word.resize((lettering_width, lettering_height), Image.LANCZOS)
    card.paste(lettering, (520, 220), lettering)

    font_path = os.path.join(ROOT, 'docs', 'assets', 'fonts', 'Baloo2.ttf')
    if os.path.exists(font_path):
        tagline = 'Learn to solve your cube, one step at a time'
        draw = ImageDraw.Draw(card)
        available = card_width - 520 - 40
        # Shrink until it fits rather than trusting a hard-coded size.
        for size in range(38, 17, -1):
            try:
                font = ImageFont.truetype(font_path, size)
            except OSError:
                break
            left, _, right, _ = draw.textbbox((0, 0), tagline, font=font)
            if right - left <= available:
                draw.text((524, 224 + lettering_height + 16), tagline,
                          font=font, fill=(200, 214, 230))
                break

    card.save(os.path.join(DOCS, 'og.png'))


def main():
    if not os.path.exists(SOURCE):
        sys.exit(f'missing artwork: {SOURCE}')
    source = Image.open(SOURCE)
    print(f'source artwork {source.size[0]}x{source.size[1]}')
    build_app_icon(source)
    build_launch_logo(source)
    report_launch_background(source)
    build_brand_mark(source)
    build_wordmark(source)
    build_web_assets(source)
    print('done')


if __name__ == '__main__':
    main()
