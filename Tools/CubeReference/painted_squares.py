"""A square painted by hand, and what else it tells us.

The twin of re-reading the scan with painted squares locked, in
`NoobCube/Scan/ScanCoordinator.swift`. A painted square is taken as right,
above anything the camera saw: it costs nothing as its own colour and is
ruled out as any other. Settling then builds whole pieces around it, so the
rest of its piece, and any piece that can now only go somewhere else, follow.
Gently first, with a painted square free as its own colour; only when that
reading would leave a painted square unpainted, firmly, priced below zero so
its slot is filled before any other takes the piece it needs.

    python3 Tools/CubeReference/painted_squares.py [scans]

Measured over 1500: of the 48 that came out wrong, painting one square put
19 completely right; the first tap put 1.33 other wrong squares right on
average; 47 of 48 needed fewer taps than there were wrong squares.
"""
import os
import random
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import colours as C

def settle_locked(raw, centres, locks):
    """Gently first: a painted square free as its own colour. Only if that
    reading leaves a painted square unpainted, firmly: owed, so its slot is
    filled before anything else takes the piece it needs."""
    gentle = _settle_locked(raw, centres, locks, owed=0.0)
    if all(gentle[i] == c for i, c in locks.items()):
        return gentle
    return _settle_locked(raw, centres, locks, owed=-1000.0)


def _settle_locked(raw, centres, locks, owed):
    """colours.settle, with painted squares free as their own colour and ruled out as any other."""
    light = C.illuminant_of_scan(raw, centres, True)
    samples = C.levelled(C.white_balanced(C.divide(raw, light) if light else raw))
    palette = C.Palette.measured({C.FACES[f]: samples[f*9:f*9+9] for f in range(6)}, centres)
    top = [max(C.hsv(samples[f*9+o])[2] for o in range(9)) or 1.0 for f in range(6)]
    def price(i, c):
        # Owed, not merely free: pieces go cheapest first, so a painted
        # square's slot has to be filled before anything else takes its piece.
        if i in locks: return owed if c == locks[i] else 1000.0
        p = C.cost(samples[i], c) * (C.FIXED_REFERENCE_SHARE if not palette.is_empty else 1.0)
        if not palette.is_empty: p += palette.distance(samples[i], c, C.hsv(samples[i])[2] / top[i//9])
        return p
    a = [None]*54
    for f in range(6): a[f*9+4] = centres[C.FACES[f]]
    C._fill(a, C.EDGE_SLOTS, C.EDGE_FACES, centres, price)
    C._fill(a, C.CORNER_SLOTS, C.CORNER_FACES, centres, price)
    return a

rng = random.Random(9)
tried = fixed_by_one = fixed_by_paint_all = 0
extra = []
N = int(sys.argv[1]) if len(sys.argv) > 1 else 400
for _ in range(N):
    truth, looks = C.a_scan(rng)
    flat = [s for f in C.FACES for s in looks[f]]
    got, _ = C.settle(flat, C.SCHEME)
    wrong = [i for i in range(54) if got[i] != truth[i]]
    if not wrong: continue
    tried += 1
    # The child notices one wrong square and paints it right.
    i = wrong[0]
    after = settle_locked(flat, C.SCHEME, {i: truth[i]})
    if after == truth: fixed_by_one += 1
    # And how many squares that one tap put right besides itself.
    extra.append(sum(1 for j in wrong if j != i and after[j] == truth[j]))
    # Painting squares one at a time, re-reading after each, until right.
    locks = {}
    cur = got
    for _ in range(len(wrong)):
        w = [j for j in range(54) if cur[j] != truth[j]]
        if not w: break
        locks[w[0]] = truth[w[0]]
        cur = settle_locked(flat, C.SCHEME, locks)
    taps = len(locks)
    fixed_by_paint_all += taps < len(wrong) or cur == truth and taps < len(wrong)
print(f"scans that came out wrong: {tried} of {N}")
print(f"  put completely right by painting just one square: {fixed_by_one}")
print(f"  other wrong squares each first tap also put right: mean {sum(extra)/len(extra):.2f}")
print(f"  needed fewer taps than there were wrong squares: {fixed_by_paint_all}")

assert fixed_by_one > 0, 'one painted square never put a scan right'
assert sum(extra) > 0, 'a painted square never told us anything else'
print('ALL PASS')
