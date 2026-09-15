"""Reference cube model derived purely from geometry (no memorised tables).

Axes: x = right (R), y = up (U), z = front (F).
A sticker is (cubie position, outward face normal), both in {-1,0,1}^3.
Facelet order is Kociemba's: U(0-8) R(9-17) F(18-26) D(27-35) L(36-44) B(45-53).
"""

FACES = ['U', 'R', 'F', 'D', 'L', 'B']

NORMAL = {
    'U': (0, 1, 0),
    'R': (1, 0, 0),
    'F': (0, 0, 1),
    'D': (0, -1, 0),
    'L': (-1, 0, 0),
    'B': (0, 0, -1),
}

def cross(a, b):
    return (a[1]*b[2] - a[2]*b[1],
            a[2]*b[0] - a[0]*b[2],
            a[0]*b[1] - a[1]*b[0])

def dot(a, b):
    return a[0]*b[0] + a[1]*b[1] + a[2]*b[2]

def neg(a):
    return (-a[0], -a[1], -a[2])

def add(a, b):
    return (a[0]+b[0], a[1]+b[1], a[2]+b[2])

# Image-space basis for each face when looking at it from outside.
# `up` is the direction that points to the top of that face in the standard net,
# `right` is derived as forward x up, where forward is the viewing direction.
FACE_UP = {
    'U': (0, 0, -1),   # U is drawn with the B edge at the top
    'D': (0, 0, 1),    # D is drawn with the F edge at the top
    'F': (0, 1, 0),
    'B': (0, 1, 0),
    'R': (0, 1, 0),
    'L': (0, 1, 0),
}

def face_basis(f):
    n = NORMAL[f]
    forward = neg(n)          # viewer looks along -n, towards the cube
    up = FACE_UP[f]
    right = cross(forward, up)
    return up, right

def sticker_index(pos, normal):
    """Facelet index 0..53 for the sticker at `pos` facing `normal`."""
    f = [k for k, v in NORMAL.items() if v == normal][0]
    up, right = face_basis(f)
    # position within the face plane: row grows downwards (-up), col grows with right
    row = 1 - dot(pos, up)
    col = 1 + dot(pos, right)
    return FACES.index(f) * 9 + row * 3 + col

def all_stickers():
    out = []
    for x in (-1, 0, 1):
        for y in (-1, 0, 1):
            for z in (-1, 0, 1):
                pos = (x, y, z)
                for n in NORMAL.values():
                    if dot(pos, n) == 1:
                        out.append((pos, n))
    return out

def rotate_cw(v, axis):
    """Rotate v a quarter turn clockwise as seen from outside along +axis.

    Clockwise-from-outside is -90 degrees in the right-hand sense, which
    Rodrigues reduces to  v -> -(axis x v) + axis*(axis.v)  for 90 degrees.
    """
    return add(neg(cross(axis, v)), tuple(axis[i] * dot(axis, v) for i in range(3)))

def layer_permutation(axis, selector):
    """Permutation p where p[i] = index of the facelet that MOVES INTO slot i."""
    perm = list(range(54))
    for pos, n in all_stickers():
        if not selector(pos):
            continue
        src = sticker_index(pos, n)
        dst = sticker_index(rotate_cw(pos, axis), rotate_cw(n, axis))
        perm[dst] = src
    return perm

def face_selector(f):
    n = NORMAL[f]
    return lambda pos: dot(pos, n) == 1

def slice_selector(axis):
    return lambda pos: dot(pos, axis) == 0

def whole_selector(_pos):
    return True

BASE = {}
for f in FACES:
    BASE[f] = layer_permutation(NORMAL[f], face_selector(f))

# Slice moves follow the face they share a direction with:
# M follows L, E follows D, S follows F.
BASE['M'] = layer_permutation(NORMAL['L'], slice_selector((1, 0, 0)))
BASE['E'] = layer_permutation(NORMAL['D'], slice_selector((0, 1, 0)))
BASE['S'] = layer_permutation(NORMAL['F'], slice_selector((0, 0, 1)))

# Whole-cube rotations.
BASE['x'] = layer_permutation(NORMAL['R'], whole_selector)
BASE['y'] = layer_permutation(NORMAL['U'], whole_selector)
BASE['z'] = layer_permutation(NORMAL['F'], whole_selector)

SOLVED = ''.join(f * 9 for f in FACES)

def apply_perm(state, perm):
    return ''.join(state[perm[i]] for i in range(54))

def compose(p, q):
    """Permutation for 'do p, then q'."""
    return [p[q[i]] for i in range(54)]

MOVES = {}
for name, perm in BASE.items():
    MOVES[name] = perm
    MOVES[name + "2"] = compose(perm, perm)
    MOVES[name + "'"] = compose(compose(perm, perm), perm)

def apply(state, seq):
    if isinstance(seq, str):
        seq = seq.split()
    for m in seq:
        state = apply_perm(state, MOVES[m])
    return state

def invert(seq):
    if isinstance(seq, str):
        seq = seq.split()
    inv = []
    for m in reversed(seq):
        if m.endswith("'"):
            inv.append(m[:-1])
        elif m.endswith("2"):
            inv.append(m)
        else:
            inv.append(m + "'")
    return inv


ROTATION_BASES = {'x', 'y', 'z'}


def relabel(state):
    """Rename colours so each centre reads as its own face again.

    After a whole-cube rotation the stickers have moved but keep their old
    names, so a solved cube no longer reads as solved. Renaming by the centres
    is exactly what a person does when they re-grip the cube.
    """
    m = {}
    for i, f in enumerate(FACES):
        m[state[i * 9 + 4]] = f
    return ''.join(m[c] for c in state)


def apply_regrip(state, seq):
    """Like apply(), but a whole-cube rotation also re-labels the colours."""
    if isinstance(seq, str):
        seq = seq.split()
    for m in seq:
        state = apply_perm(state, MOVES[m])
        if m[0] in ROTATION_BASES:
            state = relabel(state)
    return state
