"""Edge and corner slot tables, derived from the geometry in cube.py."""
import cube

def _nonzero(p):
    return sum(1 for c in p if c != 0)

def _faces_of(pos):
    return [f for f, n in cube.NORMAL.items() if cube.dot(pos, n) == 1]

EDGES = {}    # name -> list of (face, facelet index)
CORNERS = {}

for x in (-1, 0, 1):
    for y in (-1, 0, 1):
        for z in (-1, 0, 1):
            pos = (x, y, z)
            k = _nonzero(pos)
            if k not in (2, 3):
                continue
            fs = _faces_of(pos)
            # canonical name: U/D first, then F/B, then R/L
            order = {'U': 0, 'D': 1, 'F': 2, 'B': 3, 'R': 4, 'L': 5}
            fs.sort(key=lambda f: order[f])
            name = ''.join(fs)
            entry = [(f, cube.sticker_index(pos, cube.NORMAL[f])) for f in fs]
            (EDGES if k == 2 else CORNERS)[name] = entry

U_EDGES = [n for n in EDGES if 'U' in n]
D_EDGES = [n for n in EDGES if 'D' in n]
MID_EDGES = [n for n in EDGES if 'U' not in n and 'D' not in n]
U_CORNERS = [n for n in CORNERS if 'U' in n]
D_CORNERS = [n for n in CORNERS if 'D' in n]

def stickers(state, slot_entry):
    """[(face_of_slot, colour_letter), ...]"""
    return [(f, state[i]) for f, i in slot_entry]

def find_edge(state, colours):
    """Return (slot_name, [(face, colour), ...]) for the edge carrying `colours`."""
    want = set(colours)
    for name, entry in EDGES.items():
        s = stickers(state, entry)
        if {c for _, c in s} == want:
            return name, s
    raise LookupError(f'edge {colours} not found')

def find_corner(state, colours):
    want = set(colours)
    for name, entry in CORNERS.items():
        s = stickers(state, entry)
        if {c for _, c in s} == want:
            return name, s
    raise LookupError(f'corner {colours} not found')
