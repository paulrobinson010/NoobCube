"""Reading sticker colours off a camera — the twin of NoobCube/Scan.

`ColourClassifier.swift` names a square against six fixed references, and
`ColourPalette.swift` names it against the six colours this cube has actually
shown. This is the same thing written twice, plus a camera and a room to point
it at, so the claims in those files are numbers rather than opinions.

    python3 Tools/CubeReference/colours.py
"""
import collections
import random
import statistics

import cube
import slots as _slots

COLOURS = ['white', 'yellow', 'green', 'blue', 'red', 'orange']
FACES = cube.FACES                      # U R F D L B
FACE_OF = {f: i for i, f in enumerate(FACES)}
SCHEME = {'U': 'yellow', 'R': 'orange', 'F': 'green',
          'D': 'white', 'L': 'red', 'B': 'blue'}
ASK_ORDER = ['U', 'D', 'F', 'R', 'B', 'L']

HUE_REF = {'red': 0.0, 'orange': 28.0, 'yellow': 55.0, 'green': 135.0, 'blue': 215.0}

# CubeColour.rgb: the drawing palette, used as "what this colour is".
DRAW_RGB = {
    'white':  (0.953, 0.953, 0.953),
    'yellow': (1.000, 0.847, 0.016),
    'green':  (0.035, 0.839, 0.278),
    'blue':   (0.020, 0.439, 0.992),
    'red':    (0.992, 0.106, 0.082),
    'orange': (0.996, 0.533, 0.016),
}

# What the stickers on a real cube reflect. Blue and red are the dark ones;
# white is the only one bright in all three channels.
REFLECT = {
    'white':  (0.90, 0.90, 0.90),
    'yellow': (0.95, 0.78, 0.05),
    'red':    (0.75, 0.06, 0.08),
    'orange': (0.95, 0.35, 0.02),
    'green':  (0.05, 0.60, 0.25),
    'blue':   (0.03, 0.20, 0.70),
}

# Rooms to photograph a cube in: neutral, a warm lamp, a very warm lamp, and a
# cool daylight one.
LIGHTS = [(1, 1, 1), (1, 0.92, 0.80), (1, 0.85, 0.65), (0.90, 0.95, 1.0)]

DIMMEST_PLAUSIBLE_CHANNEL = 0.30
PALE_ENOUGH_TO_BE_WHITE = 0.30
FIXED_REFERENCE_SHARE = 4.0
BRIGHTNESS_IN_CONTEXT = 2.5


# --------------------------------------------------------------- RGBSample.hsv

def hsv(s):
    r, g, b = s
    mx, mn = max(r, g, b), min(r, g, b)
    d = mx - mn
    h = 0.0
    if d > 0.0001:
        if mx == r:
            h = 60 * (((g - b) / d) % 6)
        elif mx == g:
            h = 60 * ((b - r) / d + 2)
        else:
            h = 60 * ((r - g) / d + 4)
    if h < 0:
        h += 360
    return h, (0.0 if mx <= 0.0001 else d / mx), mx


def hue_gap(a, b):
    d = abs(a - b)
    return 360 - d if d > 180 else d


def mean(samples):
    n = float(max(len(samples), 1))
    return tuple(sum(s[c] for s in samples) / n for c in range(3))


def divide(samples, light):
    return [tuple(min(1.0, s[c] / light[c]) for c in range(3)) for s in samples]


# ------------------------------------------------------- ColourClassifier.cost

def cost(sample, colour):
    h, s, v = hsv(sample)
    if colour == 'white':
        return s * 2.2 + max(0, 0.55 - v) * 1.5
    washed = max(0, 0.34 - s) * 3.0
    return hue_gap(h, HUE_REF[colour]) / 45.0 + washed + max(0, 0.30 - v) * 1.2


def best_guess(sample):
    return min(COLOURS, key=lambda c: cost(sample, c))


def cost_of_best_guess(sample):
    return min(cost(sample, c) for c in COLOURS)


# ------------------------------------------------ taking the colour of the light out

def illuminant_from(sample, known):
    r, g, b = DRAW_RGB[known]
    if min(r, g, b) <= 0.4:
        return None
    ratio = [sample[0] / r, sample[1] / g, sample[2] / b]
    strongest = max(ratio)
    if strongest <= 0.001:
        return None
    norm = tuple(x / strongest for x in ratio)
    return None if min(norm) < DIMMEST_PLAUSIBLE_CHANNEL else norm


def matching(index, samples):
    ah, asat, _ = hsv(samples[index])
    out = []
    for s in samples:
        h, sat, _ = hsv(s)
        if hue_gap(h, ah) < 20 and abs(sat - asat) < 0.18:
            out.append(s)
    return out


def face_fit(samples, centre):
    """How well nine readings account for themselves as one side of a cube."""
    total = 0.0
    for i, s in enumerate(samples):
        total += cost(s, centre) if (i == 4 and centre) else cost_of_best_guess(s)
    return total


def worth_using(light, samples, centre):
    """Whether a light worked out from one square is worth applying.

    The palest square is only a white one if the face has a white square on it,
    and most do not. Take a blue square instead and the arithmetic still
    produces a light — and blue is the one sticker colour it produces a
    *believable* light from, because a washed-out blue normalises to an
    ordinary cool daylight while a washed-out red or green normalises to
    something no lamp is and gets thrown out. The middle's colour is known
    before the camera sees it, and a light that is really there makes the rest
    of the face read better.
    """
    relit = divide(samples, light)
    if centre and best_guess(relit[4]) != centre:
        return False
    return face_fit(relit, centre) < face_fit(samples, centre)


def illuminant_on_face(samples, centre=None, guarded=True):
    if len(samples) != 9:
        return None
    if centre and min(DRAW_RGB[centre]) > 0.4:
        light = illuminant_from(mean(matching(4, samples)), centre)
        if light:
            return light
    sats = [hsv(s)[1] for s in samples]
    palest, strongest = min(sats), max(sats)
    if strongest <= 0.001 or 1 - palest / strongest < PALE_ENOUGH_TO_BE_WHITE:
        return None
    light = illuminant_from(mean(matching(sats.index(palest), samples)), 'white')
    if light and guarded and not worth_using(light, samples, centre):
        return None
    return light


def relit(samples, centre=None, guarded=True):
    light = illuminant_on_face(samples, centre, guarded)
    return divide(samples, light) if light else samples


# ---------------------------------------------------------------- ColourPalette

class Palette:
    """The six colours as this cube has actually shown them, in this room."""

    def __init__(self, reference):
        self.reference = dict(reference)
        top = max([hsv(r)[2] for r in reference.values()] or [1.0]) or 1.0
        self.brightness = {c: hsv(r)[2] / top for c, r in reference.items()}

    @property
    def is_empty(self):
        return not self.reference

    @classmethod
    def measured(cls, looks, centres):
        """Each look's middle is a square of known colour; then refined twice.

        The middle is taken on its own rather than averaged with the squares
        that look like it: orange and red sit about twenty degrees apart, close
        enough that "the squares like this one" mixes the two references
        together and loses the very distinction the palette exists to make.
        """
        ref = {centres[f]: s[4] for f, s in looks.items()
               if len(s) == 9 and f in centres}
        # All six or none. A square is named by whichever colour it is nearest,
        # so a half-built palette would measure some colours and fall back to
        # the fixed references for the rest, and the two are not on the same
        # scale — the comparison goes to whichever happened to be scored the
        # more generously. Measured while scanning side by side, that traded
        # blue read as white (3.7% of blue squares down to 2.0%) for red and
        # orange read as each other (0.2% up to 1.9%), which is no trade at all.
        if len(ref) < len(COLOURS):
            return cls({})
        palette = cls(ref)
        squares = [s for look in looks.values() for s in look]
        for _ in range(2):
            groups = collections.defaultdict(list)
            for s in squares:
                groups[palette.nearest(s)].append(s)
            for c, group in groups.items():
                if len(group) >= 3:
                    ref[c] = mean(group)
            palette = cls(ref)
        return palette

    def distance(self, sample, colour, relative_brightness=None):
        ref = self.reference.get(colour)
        if ref is None:
            return cost(sample, colour)
        h, s, _ = hsv(sample)
        rh, rs, _ = hsv(ref)
        has_hue = min(1.0, min(s, rs) / 0.25)
        total = hue_gap(h, rh) / 45.0 * has_hue + abs(s - rs) * 1.6
        total += tint_gap(sample, ref) * 3.0
        if relative_brightness is not None and colour in self.brightness:
            total += abs(relative_brightness - self.brightness[colour]) * BRIGHTNESS_IN_CONTEXT
        return total

    def nearest(self, sample):
        return min(COLOURS, key=lambda c: self.distance(sample, c))

    def names_on_face(self, samples):
        """All nine at once: how dark a square is only means something next to
        the others sharing its light."""
        if self.is_empty:
            return [best_guess(s) for s in samples]
        top = max(hsv(s)[2] for s in samples)
        if top <= 0.001:
            return [best_guess(s) for s in samples]
        return [min(COLOURS, key=lambda c: self.distance(s, c, hsv(s)[2] / top))
                for s in samples]


def tint(sample):
    total = sum(sample) + 0.000001
    return tuple(c / total for c in sample)


def tint_gap(a, b):
    ta, tb = tint(a), tint(b)
    return sum(abs(ta[i] - tb[i]) for i in range(3))


# ------------------------------------------------------------- settling a scan

def white_point(samples):
    whitest = sorted(samples, key=lambda s: -hsv(s)[2] + hsv(s)[1] * 0.6)[:9]
    pt = [sum(s[c] for s in whitest) / float(len(whitest)) for c in range(3)]
    strongest = max(pt)
    if strongest <= 0.001:
        return (1.0, 1.0, 1.0)
    return tuple(max(p / strongest, 0.001) for p in pt)


def white_balanced(samples):
    return divide(samples, white_point(samples))


def levelled(samples):
    values = sorted(hsv(s)[2] for s in samples)
    target = values[len(values) // 2]
    if target <= 0.001:
        return samples
    out = list(samples)
    for f in range(6):
        idx = range(f * 9, f * 9 + 9)
        middle = sorted(hsv(samples[i])[2] for i in idx)[4]
        if middle <= 0.001:
            continue
        scale = target / middle
        for i in idx:
            out[i] = tuple(min(1.0, samples[i][c] * scale) for c in range(3))
    return out


def median(xs):
    return statistics.median(xs)


def illuminant_of_scan(samples, centres, guarded=True):
    lights = []
    for f in range(6):
        light = illuminant_on_face(samples[f * 9:f * 9 + 9], centres.get(FACES[f]), guarded)
        if light:
            lights.append(light)
    if not lights:
        return None
    mid = [median([l[c] for l in lights]) for c in range(3)]
    strongest = max(mid)
    return None if strongest <= 0.001 else tuple(m / strongest for m in mid)


def _det(a, b, c):
    return (a[0] * (b[1] * c[2] - b[2] * c[1])
            - a[1] * (b[0] * c[2] - b[2] * c[0])
            + a[2] * (b[0] * c[1] - b[1] * c[0]))


def _cyclic(entry):
    """Three corner stickers going round the same way every time.

    The canonical slot name (U/D, F/B, R/L) is not a rotational order, so
    cycling those three by one is not a twist of the piece. The sign of the
    determinant of the three face normals says which way round they go.
    """
    normals = [cube.NORMAL[f] for f, _ in entry]
    return entry if _det(*normals) > 0 else [entry[0], entry[2], entry[1]]


EDGE_SLOTS = [[i for _, i in e] for e in _slots.EDGES.values()]
EDGE_FACES = [[f for f, _ in e] for e in _slots.EDGES.values()]
_CORNERS = [_cyclic(c) for c in _slots.CORNERS.values()]
CORNER_SLOTS = [[i for _, i in c] for c in _CORNERS]
CORNER_FACES = [[f for f, _ in c] for c in _CORNERS]


def _fill(assignment, slot_idx, slot_faces, naming, price):
    """Hand out one set of slots — all the edges, or all the corners.

    Every piece the cube has is used exactly once, so a square read badly can
    only spoil the piece it is on.
    """
    pieces = [[naming[f] for f in fs] for fs in slot_faces]
    sides = len(pieces[0])
    options = []
    for s, idx in enumerate(slot_idx):
        for p, piece in enumerate(pieces):
            for turn in range(sides):
                options.append((sum(price(idx[k], piece[(k + turn) % sides])
                                    for k in range(sides)), s, p, turn))
    options.sort()
    slot_taken = [False] * len(slot_idx)
    piece_taken = [False] * len(pieces)
    for _, s, p, turn in options:
        if slot_taken[s] or piece_taken[p]:
            continue
        slot_taken[s] = piece_taken[p] = True
        for k in range(sides):
            assignment[slot_idx[s][k]] = pieces[p][(k + turn) % sides]


def settle(raw, centres, use_palette=True, guarded=True):
    """The whole 54-square reading, the way the app settles it."""
    light = illuminant_of_scan(raw, centres, guarded)
    samples = levelled(white_balanced(divide(raw, light) if light else raw))

    palette = Palette.measured(
        {FACES[f]: samples[f * 9:f * 9 + 9] for f in range(6)}, centres) \
        if use_palette else Palette({})
    top = [max(hsv(samples[f * 9 + o])[2] for o in range(9)) or 1.0 for f in range(6)]

    def price(i, c):
        p = cost(samples[i], c) * (FIXED_REFERENCE_SHARE if not palette.is_empty else 1.0)
        if not palette.is_empty:
            p += palette.distance(samples[i], c, hsv(samples[i])[2] / top[i // 9])
        return p

    assignment = [None] * 54
    for f in range(6):
        assignment[f * 9 + 4] = centres[FACES[f]]
    _fill(assignment, EDGE_SLOTS, EDGE_FACES, centres, price)
    _fill(assignment, CORNER_SLOTS, CORNER_FACES, centres, price)

    # Chosen with the palette's help, reported on without it, so that how well a
    # scan explains its pixels stays the measurement `tooPoorToBelieve` was
    # calibrated against.
    fit = sum(cost(samples[i], assignment[i]) for i in range(54) if i % 9 != 4)
    return assignment, fit / 48


# ------------------------------------------------------------------- the room

def camera(colour, light=(1, 1, 1), gain=1.0, haze=0.0, noise=0.0, rng=None):
    """One square as the phone sees it: lit, veiled by glare, clipped.

    `haze` is veiling glare — a light source reflected off shiny plastic pulls
    every square towards a bright grey. It is the thing that breaks colour
    naming, and the thing every earlier test of this code left out.
    """
    r = REFLECT[colour]
    out = []
    for c in range(3):
        v = r[c] * light[c] * gain
        v = v * (1 - haze) + 0.92 * gain * light[c] * haze
        if rng and noise:
            v += rng.gauss(0, noise)
        out.append(min(1.0, max(0.0, v)))
    return tuple(out)


def scramble_colours(rng):
    moves, last = [], None
    for _ in range(25):
        f = rng.choice([x for x in 'URFDLB' if x != last])
        last = f
        moves.append(f + rng.choice(['', "'", '2']))
    return [SCHEME[c] for c in cube.apply(cube.SOLVED, moves)]


def one_look(truth, face, light, gain, haze, shade, rng):
    """Nine readings of one side, with a lighting gradient across it."""
    out = []
    f = FACE_OF[face]
    for o in range(9):
        row, col = divmod(o, 3)
        local = gain * (1 - shade * (row + col) / 4.0)
        s = camera(truth[f * 9 + o], light=light, gain=local, haze=haze)
        out.append(tuple(min(1.0, max(0.0, c + rng.gauss(0, 0.01))) for c in s))
    return out


def a_scan(rng, guarded=True):
    truth = scramble_colours(rng)
    room = dict(light=rng.choice(LIGHTS),
                gain=rng.choice([1.0, 0.8, 0.55]),
                haze=rng.choice([0.0, 0.15, 0.3, 0.45]),
                shade=rng.choice([0.0, 0.15, 0.3]))
    looks = {f: relit(one_look(truth, f, rng=rng, **room), SCHEME[f], guarded)
             for f in FACES}
    return truth, looks


# ------------------------------------------------------------------ checking

def _tally(truth, got, wrong, tot):
    for t, g in zip(truth, got):
        tot[t] += 1
        if t != g:
            wrong[(t, g)] += 1
    return all(t == g for t, g in zip(truth, got))


def check_the_net(trials=500, seed=77):
    """What the child watches fill in, side by side, as they scan."""
    rows = []
    for label, use_palette, guarded in [('as it was', False, False),
                                        ('light guarded', False, True),
                                        ('and a palette', True, True)]:
        rng = random.Random(seed)
        wrong, tot, perfect = collections.Counter(), collections.Counter(), 0
        for _ in range(trials):
            truth, looks = a_scan(rng, guarded)
            palette = Palette.measured(looks, SCHEME) if use_palette else Palette({})
            got = []
            for f in FACES:
                got += palette.names_on_face(looks[f])
            perfect += _tally(truth, got, wrong, tot)
        rows.append((label, 100 * sum(wrong.values()) / sum(tot.values()),
                     100 * perfect / trials,
                     100 * wrong[('blue', 'white')] / tot['blue'],
                     100 * wrong[('yellow', 'orange')] / tot['yellow'],
                     100 * (wrong[('red', 'orange')] + wrong[('orange', 'red')])
                     / (tot['red'] + tot['orange'])))
    print('the net as the child sees it        squares  perfect  blue→white'
          '  yellow→orange  red↔orange')
    for r in rows:
        print('  %-30s %6.2f%% %7.1f%% %10.1f%% %13.1f%% %10.1f%%' % r)


def check_the_settled_scan(trials=500, seed=77):
    """And the cube the app ends up with, once the pieces have to add up."""
    print('the cube it settles on              squares  perfect   worst confusion')
    for label, use_palette, guarded in [('as it was', False, False),
                                        ('light guarded', False, True),
                                        ('and a palette', True, True)]:
        rng = random.Random(seed)
        wrong, tot, perfect, fits = collections.Counter(), collections.Counter(), 0, []
        for _ in range(trials):
            truth, looks = a_scan(rng, guarded)
            flat = [s for f in FACES for s in looks[f]]
            got, fit = settle(flat, SCHEME, use_palette, guarded)
            fits.append(fit)
            perfect += _tally(truth, got, wrong, tot)
        worst = max(wrong.items(), key=lambda kv: kv[1]) if wrong else (('—', '—'), 0)
        print('  %-30s %6.2f%% %7.1f%%   %s→%s %.1f%%   (median fit %.2f)'
              % (label, 100 * sum(wrong.values()) / sum(tot.values()),
                 100 * perfect / trials, worst[0][0], worst[0][1],
                 100 * worst[1] / tot[worst[0][0]], median(fits)))


def check_a_cube_is_still_told_from_a_wall(trials=300, seed=5):
    """`tooPoorToBelieve` has to keep meaning what it meant.

    The reading is chosen with the palette's help now, so the assignment can
    differ — but it is reported on with the fixed references alone, so a real
    cube must still come in well under 0.62 and a lump of nothing well over.
    """
    rng = random.Random(seed)
    cubes, junk = [], []
    for _ in range(trials):
        truth, looks = a_scan(rng)
        cubes.append(settle([s for f in FACES for s in looks[f]], SCHEME)[1])
        junk.append(settle([(rng.random(), rng.random(), rng.random())
                            for _ in range(54)], SCHEME)[1])
    print('a real cube  worst %.2f  (must stay under 0.62)' % max(cubes))
    print('random noise best  %.2f  (must stay over  0.62)' % min(junk))
    assert max(cubes) < 0.62, max(cubes)
    assert min(junk) > 0.62, min(junk)
    print('ALL PASS')


if __name__ == '__main__':
    check_the_net()
    print()
    check_the_settled_scan()
    print()
    check_a_cube_is_still_told_from_a_wall()
