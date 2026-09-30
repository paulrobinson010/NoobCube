"""The faster methods: the white cross straight onto the bottom, the first two
layers a corner-and-edge pair at a time, then the last layer by algorithm.

  Faster:      cross, pairs, then the last layer in four looks (two-look OLL
               and two-look PLL: 13 algorithms)
  Speedcuber:  cross, pairs, then the last layer in two looks (full OLL and
               PLL: 78 algorithms)

Everything is face turns and whole-cube turns, as in the beginner method, so a
smart cube can follow every move and a child can copy every arrow. Stages come
out in the same shape as solver.solve(), so solver.split_steps() and the marks
work on them unchanged.

The cross and the pairs are found by search, not by table: each piece is
followed by one of its stickers, and a short iterative-deepening search finds
the fewest turns that put it home without disturbing anything already done.
"""
from collections import deque
import cube
import slots
import solver
import last_layer as LL

# DEST[m][i]: where the sticker at i goes when m is turned.
DEST = {}
for _m, _perm in cube.MOVES.items():
    _d = [0] * 54
    for _dst, _src in enumerate(_perm):
        _d[_src] = _dst
    DEST[_m] = _d


def turns_of(faces):
    return [f + s for f in faces for s in ('', "'", '2')]


# The cross is put in from the front, so the back is never needed; the bottom
# only when nothing shorter works.
CROSS_TURNS = [turns_of('URFL'), turns_of('URFLD')]
# A pair goes in at the front right. These three faces are all that the
# forty-one standard cases need, and they are the three a child can see.
PAIR_TURNS = turns_of('URF')


def home_of(colours, colour):
    """The square a piece's `colour` sticker sits on when the piece is home."""
    table = slots.EDGES if len(colours) == 2 else slots.CORNERS
    return dict(table[solver.slot_name(colours)])[colour]


def where_is(state, colours, colour):
    table = slots.EDGES if len(colours) == 2 else slots.CORNERS
    find = slots.find_edge if len(colours) == 2 else slots.find_corner
    at, _ = find(state, set(colours))
    for face, index in table[at]:
        if state[index] == colour:
            return index
    raise LookupError(colours)


# ------------------------------------------------------------ search

_TABLES = {}


def distance_table(homes, turns):
    """Fewest turns from every arrangement of these stickers back to `homes`."""
    key = (homes, tuple(turns))
    if key not in _TABLES:
        dist = {homes: 0}
        todo = deque([homes])
        while todo:
            at = todo.popleft()
            d = dist[at] + 1
            for m in turns:
                nxt = tuple(DEST[m][i] for i in at)
                if nxt not in dist:
                    dist[nxt] = d
                    todo.append(nxt)
        _TABLES[key] = dist
    return _TABLES[key]


def search(start, homes, groups, turns, limit, goal=None):
    """Shortest turns taking the stickers at `start` to `homes`.

    `groups` are index sets whose joint distance is looked up in a table and
    used as the lower bound, which is what keeps the search small. `goal`, if
    given, replaces "everything home" (for lifting a piece out of the way).
    Returns None when nothing within `limit` works.
    """
    tables = [(g, distance_table(tuple(homes[i] for i in g), turns)) for g in groups]
    done = goal or (lambda at: at == homes)
    far = limit + 1

    def bound(at):
        return max((t.get(tuple(at[i] for i in g), far) for g, t in tables), default=0)

    path = []

    def dig(at, depth, last):
        if depth == 0:
            return done(at)
        if bound(at) > depth:
            return False
        for m in turns:
            if m[0] == last:
                continue
            path.append(m)
            if dig(tuple(DEST[m][i] for i in at), depth - 1, m[0]):
                return True
            path.pop()
        return False

    for depth in range(limit + 1):
        if bound(start) > depth:
            continue
        if dig(tuple(start), depth, None):
            return list(path)
    return None


# ------------------------------------------------------------ the cross

CROSS_SIDES = ['F', 'R', 'B', 'L']


def cross_edge_home(state, side):
    return solver.d_edge_solved(state, solver.slot_name({'D', side}))


def cross_plan(state, side):
    """Turn the cube so this edge's side is in front, then the fewest turns
    that put it home and leave the edges already in the cross where they are."""
    grip = solver.y_to_front(side)
    s = cube.apply_regrip(state, grip)
    kept = [f for f in CROSS_SIDES if f != 'F' and cross_edge_home(s, f)]
    tracked = [('D', 'F')] + [('D', f) for f in kept]
    start = tuple(where_is(s, set(t), 'D') for t in tracked)
    homes = tuple(home_of(set(t), 'D') for t in tracked)
    groups = [[i] for i in range(len(tracked))]
    for turns in CROSS_TURNS:
        moves = search(start, homes, groups, turns, 8)
        if moves is not None:
            return grip, moves
    raise RuntimeError('no way to put this cross edge in')


def solve_cross(sv):
    sv.stage('cross', 'Make the white cross on the bottom')
    for _ in range(5):
        waiting = [f for f in CROSS_SIDES if not cross_edge_home(sv.state, f)]
        if not waiting:
            return
        plans = {f: cross_plan(sv.state, f) for f in waiting}
        # The cheapest first; a turn of the whole cube costs nothing.
        side = min(waiting, key=lambda f: len(plans[f][1]))
        grip, moves = plans[side]
        spin, rest = split_leading(moves, 'U')
        piece = {'D', side}
        sv.step(piece=piece, home=solver.slot_name(piece), alg_name=None,
                grip='Turn the cube so the middle that matches this edge is '
                     'facing you. The edge goes underneath it.',
                spin='Spin the top until the edge is above its gap.',
                turn='Turn a side to bring it round.',
                outcome=('It drops straight in, white on the bottom and its '
                         'colour next to the middle that matches.')
                        if len(rest) <= 2 else
                        'That brings it round and down into its place. Anything '
                        'already in the cross that moves comes straight back.')
        sv.do(grip)
        sv.do(spin)
        sv.running()
        sv.do(rest)
    raise RuntimeError('cross did not finish')


def split_leading(moves, face):
    k = 0
    while k < len(moves) and moves[k][0] == face:
        k += 1
    return moves[:k], moves[k:]


# ------------------------------------------------------------ the pairs

PAIR_SLOTS = ['FR', 'FL', 'BL', 'BR']       # middle-row slots, by their two sides


def pair_solved(state, sides):
    corner = solver.slot_name({'D'} | set(sides))
    edge = solver.slot_name(set(sides))
    return (solver.d_corner_solved(state, corner)
            and solver.mid_edge_solved(state, edge))


def kept_for_pairs(s):
    """The finished things at the front right that <U, R, F> can disturb: two
    cross edges, and the two neighbouring pairs if they are done. Each as
    (colours, colour followed)."""
    kept = [({'D', 'F'}, 'D'), ({'D', 'R'}, 'D')]
    groups = [[0, 1]]
    for sides in (('F', 'L'), ('B', 'R')):
        if pair_solved(s, sides):
            base = len(kept)
            kept += [({'D'} | set(sides), 'D'), (set(sides), sides[0])]
            groups.append([base, base + 1])
    return kept, groups


def pair_plan(state, sides, limit):
    """Turn the cube so this pair's gap is at the front right, then the fewest
    turns of the top, right and front that put both pieces in together."""
    grip = solver.y_bringing_pair(sides)
    s = cube.apply_regrip(state, grip)
    kept, kept_groups = kept_for_pairs(s)
    tracked = [({'D', 'F', 'R'}, 'D'), ({'F', 'R'}, 'F')] + kept
    start = tuple(where_is(s, c, colour) for c, colour in tracked)
    homes = tuple(home_of(c, colour) for c, colour in tracked)
    groups = [[0, 1]] + [[i + 2 for i in g] for g in kept_groups]
    moves = search(start, homes, groups, PAIR_TURNS, limit)
    return None if moves is None else (grip, moves)


def free_plan(state, unsolved):
    """Nothing can go straight in: some piece is stuck in the gap diagonally
    opposite its own. Lift one out to the top, the shortest way."""
    best = None
    for gap in PAIR_SLOTS:
        grip = solver.y_bringing_pair(gap)
        s = cube.apply_regrip(state, grip)
        # Which pieces that still need placing are sitting in the front-right
        # gap now? Corner below it, edge in it.
        stuck = []
        corner = {c for _, c in slots.stickers(s, slots.CORNERS['DFR'])}
        edge = {c for _, c in slots.stickers(s, slots.EDGES['FR'])}
        if pair_solved(s, ('F', 'R')):
            continue
        for colours, colour in ((corner, 'D' if 'D' in corner else sorted(corner)[0]),
                                (edge, sorted(edge)[0])):
            if 'U' in colours:
                continue            # a last-layer piece: not in anyone's way
            stuck.append((colours, colour))
        if not stuck:
            continue
        kept, kept_groups = kept_for_pairs(s)
        tracked = stuck[:1] + kept
        start = tuple(where_is(s, c, colour) for c, colour in tracked)
        homes = tuple([start[0]] + [home_of(c, colour) for c, colour in kept])
        groups = [[i + 1 for i in g] for g in kept_groups]
        top = set(range(9)) | {f * 9 + o for f in (1, 2, 4, 5) for o in range(3)}

        def lifted(at, homes=homes):
            return at[0] in top and at[1:] == homes[1:]
        moves = search(start, homes, groups, PAIR_TURNS, 5, goal=lifted)
        if moves is not None and (best is None or len(moves) < len(best[2])):
            best = (gap, grip, moves, stuck[0][0])
    if best is None:
        raise RuntimeError('nothing to lift out')
    return best


def solve_pairs(sv):
    sv.stage('pairs', 'Fill the first two layers, a pair at a time')
    for _ in range(12):
        unsolved = [g for g in PAIR_SLOTS if not pair_solved(sv.state, g)]
        if not unsolved:
            return
        best, limit = None, 13
        for gap in unsolved:
            plan = pair_plan(sv.state, gap, limit)
            if plan is not None and (best is None or len(plan[1]) < len(best[1][1])):
                best = (gap, plan)
                limit = len(plan[1]) - 1
        if best is None:
            gap, grip, moves, piece = free_plan(sv.state, unsolved)
            sv.step(piece=piece, home=solver.slot_name(piece), places=False,
                    grip='This piece is stuck in the wrong gap. Turn the cube so '
                         'that gap is at the front right.',
                    outcome='That lifts it out to the top, where it can be paired up.')
            sv.do(grip)
            sv.running()
            sv.do(moves)
            continue
        gap, (grip, moves) = best
        corner = {'D'} | set(gap)
        spin, rest = split_leading(moves, 'U')
        sv.step(piece=corner, home=solver.slot_name(corner), alg_name='pairing up',
                grip='Find the gap this corner belongs in: the two middles beside '
                     'it are its other colours. Turn the cube so that gap is at the '
                     'front right.',
                spin='Spin the top to get the corner and its edge ready.',
                outcome='The corner and its edge join up, then drop into the gap '
                        'together. The white cross goes away and comes straight back.'
                        if len(rest) > 3 else
                        'The corner and its edge drop into the gap together.')
        sv.do(grip)
        sv.do(spin)
        sv.running()
        sv.do(rest)
    raise RuntimeError('pairs did not finish')


# ------------------------------------------------------------ the last layer

SPIN_TEXT = {
    'eo': 'Turn the top until the yellow line lies left to right, or the L points '
          'at the back and the left.',
    'ocll': 'Turn the top until it looks like the picture for this one.',
    'cpll': 'Turn the top until the two corners that already match are on the left.',
    'epll': 'Turn the top until the side that is already right is at the back.',
    'oll': 'Turn the top until it looks like the picture for this one.',
    'pll': 'Turn the top until it looks like the picture for this one.',
}
OUTCOME = {
    'eo': 'That makes more of the yellow cross.',
    'ocll': 'The whole top goes yellow.',
    'cpll': 'Now the corners all belong together.',
    'epll': 'The edges swap round into their places.',
    'oll': 'The whole top goes yellow in one go.',
    'pll': 'Everything on top slides into place in one go.',
}


def run_looks(sv, key, looks):
    for name, spin, moves in looks:
        if key == 'oll':
            name = f'OLL {name}'
        sv.step(alg_name=name, spin=SPIN_TEXT[key], outcome=OUTCOME[key])
        sv.do(spin)
        sv.running()
        sv.do(moves)


def solve_last_layer(sv, full):
    if full:
        sv.stage('oll', 'Make the whole top yellow in one go')
        run_looks(sv, 'oll', LL.orient_one_look(sv.state))
        sv.stage('pll', 'Put the top layer in order in one go')
        run_looks(sv, 'pll', LL.permute_one_look(sv.state))
    else:
        looks = LL.orient_two_look(sv.state)
        edges = [l for l in looks if l[0] in dict(LL.EDGES)]
        sv.stage('eo', 'Make the yellow cross')
        run_looks(sv, 'eo', edges)
        sv.stage('ocll', 'Finish the yellow face')
        run_looks(sv, 'ocll', looks[len(edges):])
        looks = LL.permute_two_look(sv.state)
        corners = [l for l in looks if l[0] in dict(LL.CORNER_SWAPS)]
        sv.stage('cpll', 'Put the top corners in order')
        run_looks(sv, 'cpll', corners)
        sv.stage('epll', 'Put the top edges in order')
        run_looks(sv, 'epll', looks[len(corners):])
    sv.step(spin='One last spin of the top.', outcome='And that is the whole cube.')
    sv.do(LL.last_turn(sv.state))


# ------------------------------------------------------------ entry point

def solve(state, full=False, white_face='D'):
    sv = solver.Solve(state)
    sv.stage('hold', 'Hold your cube with white on the bottom')
    sv.step(grip='Turn the whole cube so white is underneath and yellow is on top.',
            outcome='Now left and right mean the same thing to both of us.')
    sv.do(solver.WHITE_DOWN_ROTATION[white_face])
    solve_cross(sv)
    solve_pairs(sv)
    solve_last_layer(sv, full)
    for st in sv.stages:
        for step in st['steps']:
            step['setup'] = solver.simplify(step['setup'])
            step['algorithm'] = solver.simplify(step['algorithm'])
            step['moves'] = step['setup'] + step['algorithm']
        st['steps'] = [step for step in st['steps'] if step['moves']]
        st['moves'] = [m for step in st['steps'] for m in step['moves']]
    solver.split_steps(sv, state)
    if sv.state != cube.SOLVED:
        raise RuntimeError('solver finished but the cube is not solved')
    return sv
