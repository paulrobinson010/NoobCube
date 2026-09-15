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
    from PIL import Image, ImageDraw, ImageFilter
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

def build_launch_logo(source):
    """The icon artwork as a rounded tile, centred on the launch screen."""
    folder = os.path.join(ASSETS, 'LaunchLogo.imageset')
    clear_pngs(folder)

    images = []
    base = 200                                   # points
    for scale in (1, 2, 3):
        side = base * scale
        tile = source.convert('RGBA').resize((side, side), Image.LANCZOS)
        mask = Image.new('L', (side, side), 0)
        ImageDraw.Draw(mask).rounded_rectangle((0, 0, side - 1, side - 1),
                                               radius=int(side * 0.225), fill=255)
        tile.putalpha(mask)
        name = f'LaunchLogo@{scale}x.png'
        tile.save(os.path.join(folder, name))
        images.append({'filename': name, 'idiom': 'universal', 'scale': f'{scale}x'})

    write_json(folder, {'images': images, 'info': INFO})
    print(f'  LaunchLogo         {base}pt tile')


def build_launch_background():
    folder = os.path.join(ASSETS, 'LaunchBackground.colorset')
    red, green, blue = LAUNCH_BACKGROUND
    colour = {
        'color-space': 'srgb',
        'components': {
            'alpha': '1.000',
            'red': f'{red / 255:.3f}',
            'green': f'{green / 255:.3f}',
            'blue': f'{blue / 255:.3f}',
        },
    }
    write_json(folder, {
        'colors': [{'color': colour, 'idiom': 'universal'}],
        'info': INFO,
    })
    print('  LaunchBackground   matches Theme.background')


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

def build_wordmark(source):
    """The NoobCube lettering, lifted off its background.

    The artwork sits on near-black, so brightness doubles as coverage: it gives
    the alpha, and dividing it back out of the colour recovers the real one.
    That keeps the cyan-to-magenta gradient true instead of muddy.
    """
    folder = os.path.join(ASSETS, 'BrandWordmark.imageset')
    clear_pngs(folder)

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


def main():
    if not os.path.exists(SOURCE):
        sys.exit(f'missing artwork: {SOURCE}')
    source = Image.open(SOURCE)
    print(f'source artwork {source.size[0]}x{source.size[1]}')
    build_app_icon(source)
    build_launch_logo(source)
    build_launch_background()
    build_brand_mark(source)
    build_wordmark(source)
    print('done')


if __name__ == '__main__':
    main()
