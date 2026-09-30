"""Last-layer algorithms for the faster methods, each one checked by the engine.

Only face turns (U R F D L B) are used. Wide and slice turns are what cubers
normally write, but a smart cube reports face turns, and a child copying the
picture turns faces, so every algorithm here is written the way it is done.

Two sets are built from these tables:

  Faster (two-look):  yellow cross (EO), yellow face (OCLL, 7 algorithms),
                      corners (2 algorithms), edges (4 algorithms)
  Speedcuber:         OLL (all 57 cases), PLL (all 21 cases)

Run this file to check every algorithm keeps the first two layers, solves the
case it is for, and that between them the tables cover every last layer there
is (all 62,208, found by walking the whole last-layer group).
"""
import random
import sys
from collections import deque
import cube

S = cube.SOLVED
U_TURNS = [[], ['U'], ['U2'], ["U'"]]

# The first two layers: the bottom face and the bottom two rows of each side.
F2L = [i for i in range(54) if i // 9 == 3] + \
      [f * 9 + o for f in (1, 2, 4, 5) for o in range(3, 9)]
TOP_EDGES = (1, 3, 5, 7)
# The top face and the top row of each side: where last-layer stickers live.
TOP_STICKERS = list(range(9)) + [f * 9 + o for f in (1, 2, 4, 5) for o in range(3)]


def oriented(state):
    return all(state[i] == 'U' for i in range(9))


def cross_made(state):
    return all(state[i] == 'U' for i in TOP_EDGES)


def solved_up_to_u(state):
    return any(cube.apply(state, a) == S for a in U_TURNS)


def corners_placed_up_to_u(state):
    """The corners belong together, however the top is turned."""
    corner_stickers = [f * 9 + o for f in (1, 2, 4, 5) for o in (0, 2)]
    return any(all(t[i] == S[i] for i in corner_stickers)
               for t in (cube.apply(state, a) for a in U_TURNS))


# ------------------------------------------------------------ the tables
# (name, moves).  The names are what the child hears.

EDGES = [                                   # making the yellow cross
    ('the line', "F R U R' U' F'"),
    ('the hook', "F U R U' R' F'"),
]

OCLL = [                                    # the yellow face, once the cross is made
    ('Sune', "R U R' U R U2 R'"),
    ('Anti-Sune', "R U2 R' U' R U' R'"),
    ('the H', "R U R' U R U' R' U R U2 R'"),
    ('the Pi', "R U2 R2 U' R2 U' R2 U2 R"),
    ('headlights', "R2 D R' U2 R D' R' U2 R'"),
    ('the T', "L F R' F' L' F R F'"),
    ('the bow tie', "R' F R B' R' F' R B"),
]

CORNER_SWAPS = [                            # two-look PLL, first look
    ('the T-perm', "R U R' U' R' F R2 U' R' U' R U R' F'"),
    ('the Y-perm', "F R U' R' U' R U R' F' R U R' U' R' F R F'"),
]

EDGE_CYCLES = [                             # two-look PLL, second look
    ('the Ua-perm', "R U' R U R U R U' R' U' R2"),
    ('the Ub-perm', "R2 U R U R' U' R' U' R' U R'"),
    ('the H-perm', "R2 U2 R U2 R2 U2 R2 U2 R U2 R2"),
    ('the Z-perm', "R' U' R U' R U R U' R' U R U R2 U' R' U2"),
]

# All 57, by their usual numbers. Where the usual algorithm needs wide or slice
# turns, the face-turn version here is the shortest pair of checked ones that
# does the same job.
OLL = [
    (1, "R U2 R2 F R F' U2 R' F R F'"),
    (2, "F U R U' R' F' R' U' R' F R F' U R"),
    (3, "F' U' L' U L F U' F R U R' U' F'"),
    (4, "F' U' L' U L F U F R U R' U' F'"),
    (5, "F' U' L' U L F U' F' U' L' U L F"),
    (6, "R U2 R' U' R U' R' U' F U R U' R' F'"),
    (7, "F R' F' R U2 R U2 R'"),
    (8, "R U2 R' U2 R' F R F'"),
    (9, "R U R' U' R' F R2 U R' U' F'"),
    (10, "R U R' U R' F R F' R U2 R'"),
    (11, "F' U' L' U L F U R B' R2 F R2 B R2 F' R"),
    (12, "F R U R' U' F' U F R U R' U' F'"),
    (13, "F U R U' R2 F' R U R U' R'"),
    (14, "R' F R U R' F' R F U' F'"),
    (15, "F U R U' R' F' U F' U' L' U L F"),
    (16, "F' U' L' U L F U' F U R U' R' F'"),
    (17, "F R' F' R U2 R U' B U' B' R'"),
    (18, "F R' F' R U R U' R' U F R U R' U' F'"),
    (19, "F R U R' U' F' R U2 R2 F R F' R U2 R'"),
    (20, "F' U' L' U L F R' U' R' F R F' U R"),
    (21, "R U R' U R U' R' U R U2 R'"),
    (22, "R U2 R2 U' R2 U' R2 U2 R"),
    (23, "R2 D R' U2 R D' R' U2 R'"),
    (24, "L F R' F' L' F R F'"),
    (25, "R' F R B' R' F' R B"),
    (26, "R U2 R' U' R U' R'"),
    (27, "R U R' U R U2 R'"),
    (28, "L F R' F' L' R U R U' R'"),
    (29, "R U R' U' R U' R' F' U' F R U R'"),
    (30, "F R' F R2 U' R' U' R U R' F2"),
    (31, "R' U' F U R U' R' F' R"),
    (32, "L U F' U' L' U L F L'"),
    (33, "R U R' U' R' F R F'"),
    (34, "R U R2 U' R' F R U R U' F'"),
    (35, "R U2 R2 F R F' R U2 R'"),
    (36, "L' U' L U' L' U L U L F' L' F"),
    (37, "F R' F' R U R U' R'"),
    (38, "R U R' U R U' R' U' R' F R F'"),
    (39, "L F' L' U' L U F U' L'"),
    (40, "R' F R U R' U' F' U R"),
    (41, "R U R' U R U2 R' F R U R' U' F'"),
    (42, "R' U' R U' R' U2 R F R U R' U' F'"),
    (43, "F' U' L' U L F"),
    (44, "F U R U' R' F'"),
    (45, "F R U R' U' F'"),
    (46, "R' U' R' F R F' U R"),
    (47, "F' L' U' L U L' U' L U F"),
    (48, "F R U R' U' R U R' U' F'"),
    (49, "R B' R2 F R2 B R2 F' R"),
    (50, "R' F R2 B' R2 F' R2 B R'"),
    (51, "F U R U' R' U R U' R' F'"),
    (52, "R U R' U R U' B U' B' R'"),
    (53, "R U2 R2 U' R2 U' R2 U R' F R F' U R"),
    (54, "F U R U' R2 F' R U2 R' F R F' R U2 R'"),
    (55, "R U2 R2 U' R U' R' U2 F R F'"),
    (56, "F R U R' U' F' L F R' F' L' F R F'"),
    (57, "F R' F' R2 U' R' F' U' F R U R'"),
]

PLL = [
    ('the Aa-perm', "R' F R' B2 R F' R' B2 R2"),
    ('the Ab-perm', "R B' R F2 R' B R F2 R2"),
    ('the E-perm', "R B' R' F R B R' F' R B R' F R B' R' F'"),
    ('the F-perm', "R' U' F' R U R' U' R' F R2 U' R' U' R U R' U R"),
    ('the Ga-perm', "R2 U R' U R' U' R U' R2 U' D R' U R D'"),
    ('the Gb-perm', "R' U' R U D' R2 U R' U R U' R U' R2 D"),
    ('the Gc-perm', "R2 U' R U' R U R' U R2 U D' R U' R' D"),
    ('the Gd-perm', "R U R' U' D R2 U' R U' R' U R' U R2 D'"),
    ('the H-perm', "R2 U2 R U2 R2 U2 R2 U2 R U2 R2"),
    ('the Ja-perm', "R' U L' U2 R U' R' U2 R L"),
    ('the Jb-perm', "R U R' F' R U R' U' R' F R2 U' R'"),
    ('the Na-perm', "R U R' U R U R' F' R U R' U' R' F R2 U' R' U2 R U' R'"),
    ('the Nb-perm', "R' U R U' R' F' U' F R U R' F R' F' R U' R"),
    ('the Ra-perm', "R U' R' U' R U R D R' U' R D' R' U2 R'"),
    ('the Rb-perm', "R2 F R U R U' R' F' R U2 R' U2 R"),
    ('the T-perm', "R U R' U' R' F R2 U' R' U' R U R' F'"),
    ('the Ua-perm', "R U' R U R U R U' R' U' R2"),
    ('the Ub-perm', "R2 U R U R' U' R' U' R' U R'"),
    ('the V-perm', "R' U R' U' R D' R' D R' U D' R2 U' R2 D R2"),
    ('the Y-perm', "F R U' R' U' R U R' F' R U R' U' R' F R F'"),
    ('the Z-perm', "R' U' R U' R U R U' R' U R U R2 U' R' U2"),
]


# ------------------------------------------------------------ using them

def first_that(state, table, goal):
    """The first algorithm in the table, after the first turn of the top,
    that reaches the goal: (name, top turn, moves), or None.

    Table order, then top turns in the order none, U, U2, U', so the Swift
    port picks the same one.
    """
    for a in U_TURNS:
        turned = cube.apply(state, a)
        for name, alg in table:
            if goal(cube.apply(turned, alg)):
                return name, a, alg.split()
    return None


def orient_two_look(state):
    """Yellow cross, then yellow face. A list of (name, top turn, moves).

    With no yellow edges on top (the dot) no one algorithm makes the cross, so
    the line goes first with the top as it is, which always leaves a hook or a
    line, and the second look finishes it.
    """
    out = []
    for _ in range(2):
        if cross_made(state):
            break
        found = first_that(state, EDGES, cross_made)
        if found is None:
            found = (EDGES[0][0], [], EDGES[0][1].split())
        out.append(found)
        state = cube.apply(state, found[1] + found[2])
    if not cross_made(state):
        raise ValueError('the cross did not come')
    if not oriented(state):
        found = first_that(state, OCLL, oriented)
        if found is None:
            raise ValueError('no yellow-face algorithm for this')
        out.append(found)
    return out


def orient_one_look(state):
    if oriented(state):
        return []
    found = first_that(state, [(str(n), a) for n, a in OLL], oriented)
    if found is None:
        raise ValueError('no OLL for this')
    return [found]


def permute_two_look(state):
    out = []
    if not corners_placed_up_to_u(state):
        found = first_that(state, CORNER_SWAPS, corners_placed_up_to_u)
        if found is None:
            raise ValueError('no corner swap for this')
        out.append(found)
        state = cube.apply(state, found[1] + found[2])
    if not solved_up_to_u(state):
        found = first_that(state, EDGE_CYCLES, solved_up_to_u)
        if found is None:
            raise ValueError('no edge cycle for this')
        out.append(found)
    return out


def permute_one_look(state):
    if solved_up_to_u(state):
        return []
    found = first_that(state, PLL, solved_up_to_u)
    if found is None:
        raise ValueError('no PLL for this')
    return [found]


def last_turn(state):
    for a in U_TURNS:
        if cube.apply(state, a) == S:
            return a
    raise ValueError('not solved up to a turn of the top')


def solve_last_layer(state, full):
    """Every look, then the last turn of the top. Returns (looks, final turn)."""
    looks = []
    for step in ((orient_one_look, permute_one_look) if full
                 else (orient_two_look, permute_two_look)):
        for name, a, moves in step(state):
            looks.append((name, a, moves))
            state = cube.apply(state, a + moves)
    return looks, last_turn(state)


# ------------------------------------------------------------ checks

def _perm_of(moves):
    return [i for i in cube.apply(''.join(chr(48 + i) for i in range(54)), moves)]


def every_last_layer():
    """Walk the whole last-layer group: every state with F2L solved."""
    gens = [cube.MOVES['U']]
    for alg in ("R U R' U R U2 R'", "F R U R' U' F'",
                "R U R' U' R' F R2 U' R' U' R U R' F'"):
        p = list(range(54))
        for m in alg.split():
            p = cube.compose(p, cube.MOVES[m])
        gens.append(p)
    seen = {S}
    todo = deque([S])
    while todo:
        s = todo.popleft()
        for g in gens:
            t = cube.apply_perm(s, g)
            if t not in seen:
                seen.add(t)
                todo.append(t)
    return seen


def check(sample=4000):
    tables = [('EDGES', EDGES), ('OCLL', OCLL), ('CORNER_SWAPS', CORNER_SWAPS),
              ('EDGE_CYCLES', EDGE_CYCLES), ('OLL', OLL), ('PLL', PLL)]
    for label, table in tables:
        for name, alg in table:
            moves = alg.split()
            assert all(m[0] in 'URFDLB' for m in moves), (label, name, 'not face turns')
            after = cube.apply(S, moves)
            assert all(after[i] == S[i] for i in F2L), (label, name, 'breaks F2L')

    # Each OLL solves its own number's case and no other number's.
    def case(state):
        return min(tuple(cube.apply(state, a)[i] == 'U' for i in TOP_STICKERS)
                   for a in U_TURNS)
    oll_cases = {}
    for n, alg in OLL:
        c = case(cube.apply(S, cube.invert(alg)))
        assert c not in oll_cases, ('OLL', n, 'same case as', oll_cases.get(c))
        oll_cases[c] = n
    assert len(OLL) == 57 and len(PLL) == 21

    everything = every_last_layer()
    assert len(everything) == 62208, len(everything)

    # Orientation depends only on which stickers show yellow, so one state of
    # each case stands for the rest.
    by_case = {}
    for s in everything:
        by_case.setdefault(case(s), s)
    assert len(by_case) == 58, len(by_case)       # 57 cases and done
    for c, s in by_case.items():
        for looks in (orient_one_look(s), orient_two_look(s)):
            t = s
            for _name, a, moves in looks:
                t = cube.apply(t, a + moves)
            assert oriented(t), ('orient', looks)
    edge_looks = [len([l for l in orient_two_look(s) if l[0] in dict(EDGES)])
                  for s in by_case.values()]

    oriented_ones = [s for s in everything if oriented(s)]
    assert len(oriented_ones) == 288, len(oriented_ones)
    pll_names = set()
    for s in oriented_ones:
        for step in (permute_one_look, permute_two_look):
            t = s
            for name, a, moves in step(s):
                t = cube.apply(t, a + moves)
                if step is permute_one_look:
                    pll_names.add(name)
            assert solved_up_to_u(t), ('permute', step.__name__)
    assert pll_names == {n for n, _ in PLL}, set(dict(PLL)) - pll_names

    # And whole last layers, both ways, replayed from the start. The checks
    # above already cover every case; this replays them independently. All
    # 62,208 both ways passes but takes about nine minutes, so by default it is
    # a fair sample (python3 last_layer.py all  for the lot).
    worst = {True: 0, False: 0}
    pool = sorted(everything)
    for s in (pool if sample is None else random.Random(1).sample(pool, sample)):
        for full in (True, False):
            looks, final = solve_last_layer(s, full)
            moves = [m for _n, a, ms in looks for m in a + ms] + final
            assert cube.apply(s, moves) == S
            worst[full] = max(worst[full], len(looks))
    return {
        'last layers': len(everything),
        'OLL cases': len(by_case) - 1,
        'oriented last layers': len(oriented_ones),
        'most edge looks (Faster)': max(edge_looks),
        'most looks, Speedcuber': worst[True],
        'most looks, Faster': worst[False],
    }


if __name__ == '__main__':
    for k, v in check(None if sys.argv[1:] == ['all'] else 4000).items():
        print(f'{k}: {v}')
    print('all good')
