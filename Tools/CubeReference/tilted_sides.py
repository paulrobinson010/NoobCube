"""A side shown tilted, and whether the scan can still read the cube.

The twin of `bestReading` in `NoobCube/Scan/ScanCoordinator.swift`. The four
sides are read assuming yellow is on top; a side held tilted used to go
straight into the map, and settling still made a real cube out of it -- just
not the child's. Here each side is tried every way round, one at a time over
two passes, keeping a turn only when it explains the colours better.

    python3 Tools/CubeReference/tilted_sides.py [scans] [seed]

Measured over 160: held as asked 75/80 before and after; one side tilted
0/40 -> 33/40; two sides tilted 0/40 -> 22/40. At most 104 readings a scan.
"""
import os
import random
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import colours as C

def turned(look, k):
    order = list(range(9))
    for _ in range(k % 4):
        order = [order[(2 - c) * 3 + r] for r in range(3) for c in range(3)]
    return [look[order[o]] for o in range(9)]

REAL = set(frozenset(C.SCHEME[f] for f in fs) for fs in C.EDGE_FACES + C.CORNER_FACES)
def real(a):
    seen = set()
    for slots in (C.EDGE_SLOTS, C.CORNER_SLOTS):
        for s in slots:
            p = frozenset(a[i] for i in s)
            if len(p) != len(s) or p not in REAL or p in seen: return False
            seen.add(p)
    return True

def read(looks, turns):
    flat = []
    for f in C.FACES: flat += turned(looks[f], turns.get(f, 0))
    return C.settle(flat, C.SCHEME)

def best_ud(looks, sides):
    best = None
    for u in range(4):
        for d in range(4):
            t = dict(sides); t['U'] = u; t['D'] = d
            got, fit = read(looks, t)
            if real(got) and (best is None or fit < best[1]): best = (got, fit, u, d)
    return best

def as_it_is(looks):
    b = best_ud(looks, {})
    return b[0] if b else None

def greedy(looks, passes):
    sides = {}
    base = best_ud(looks, sides)
    if base is None: return None, 16
    got, fit, u, d = base
    reads = 16
    for _ in range(passes):
        changed = False
        for side in 'FRBL':
            best_k, best_fit, best_got = sides.get(side, 0), fit, got
            for k in range(4):
                if k == sides.get(side, 0): continue
                t = dict(sides); t.update({'U': u, 'D': d, side: k})
                g, f = read(looks, t); reads += 1
                if real(g) and f < best_fit:
                    best_k, best_fit, best_got = k, f, g
            if best_k != sides.get(side, 0):
                sides[side] = best_k; got, fit = best_got, best_fit; changed = True
                again = best_ud(looks, sides); reads += 16
                if again: got, fit, u, d = again
        if not changed: break
    return got, reads

N = int(sys.argv[1]) if len(sys.argv) > 1 else 24
rng = random.Random(int(sys.argv[2]) if len(sys.argv) > 2 else 43)
res = {k: [0, 0, 0, 0] for k in ('asked', 'one', 'two')}
most = 0
for trial in range(N):
    truth, looks = C.a_scan(rng)
    kind = ['asked', 'asked', 'one', 'two'][trial % 4]
    looks = dict(looks)
    if kind != 'asked':
        for side in rng.sample('FRBL', 1 if kind == 'one' else 2):
            looks[side] = turned(looks[side], rng.choice([1, 2, 3]))
    before = as_it_is(looks)
    one, _ = greedy(looks, 1)
    two, reads = greedy(looks, 2); most = max(most, reads)
    r = res[kind]; r[0] += 1; r[1] += before == truth; r[2] += one == truth; r[3] += two == truth
print('               before   one pass   two passes')
for k, (n, b, o, t) in res.items():
    print(f"  {k:6}  {b:4}/{n:<3}  {o:4}/{n:<3}  {t:4}/{n}")
print(f"most readings in one scan: {most} (the app does 16 today)")

# Never worse for a cube held as asked, and much better for a tilted side.
assert res['asked'][3] >= res['asked'][1], 'a cube held as asked read worse'
assert res['one'][3] > res['one'][1], 'a tilted side was not forgiven'
print('ALL PASS')
