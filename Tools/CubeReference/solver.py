"""Beginner (daisy / layer-by-layer) solver.

Produces a list of stages, each a goal plus the moves that reach it.
Only these algorithms are ever used, plus whole-cube rotations, so a learner
memorises very little.
"""
from collections import deque
import cube
import slots

SEXY    = "R U R' U'".split()
INSERTR = "U R U' R' U' F' U F".split()
INSERTL = "U' L' U L U F U' F'".split()
CROSS   = "F R U R' U' F'".split()
SUNE    = "R U R' U R U2 R'".split()
APERM   = "R B' R F2 R' B R F2 R2".split()
UPERM   = "R U' R U R U R U' R' U' R2".split()

U_TURNS = [[], ['U'], ['U2'], ["U'"]]
SIDE_FACES = ['F', 'R', 'B', 'L']

# Verified against the move engine:
#   a U turn carries a top-layer piece  R -> F -> L -> B -> R
#   a y rotation brings the R face round to the front
U_STEP = {'R': 'F', 'F': 'L', 'L': 'B', 'B': 'R'}
Y_STEP = U_STEP


class Solve:
    def __init__(self, state):
        self.state = state
        self.stages = []
        self._current = None

    def stage(self, key, title):
        self._current = {'key': key, 'title': title, 'moves': []}
        self.stages.append(self._current)

    def do(self, seq):
        if isinstance(seq, str):
            seq = seq.split()
        if not seq:
            return
        self.state = cube.apply_regrip(self.state, seq)
        self._current['moves'].extend(seq)

    def all_moves(self):
        out = []
        for st in self.stages:
            out += st['moves']
        return out


# ---------------------------------------------------------------- helpers

def _steps(mapping, start, goal):
    f, k = start, 0
    while f != goal:
        f = mapping[f]
        k += 1
        if k > 4:
            raise RuntimeError('unreachable')
    return k


def u_turn_moving(src_face, dst_face):
    """U turns that carry a top-layer piece from above `src_face` to `dst_face`."""
    return U_TURNS[_steps(U_STEP, src_face, dst_face)]


def y_to_front(face):
    """Whole-cube y turns that bring `face` round to the front."""
    return [[], ['y'], ['y2'], ["y'"]][_steps(Y_STEP, face, 'F')]


def y_bringing_pair(face_pair, target=('F', 'R')):
    """y turns that move the slot spanning `face_pair` round to front-right."""
    want = set(target)
    cur = set(face_pair)
    for k in range(4):
        if cur == want:
            return [[], ['y'], ['y2'], ["y'"]][k]
        cur = {Y_STEP[f] for f in cur}
    raise RuntimeError(f'cannot bring {face_pair} to {target}')


def side_face_of(slot_name):
    return [f for f in slot_name if f in SIDE_FACES]


def bfs_alg(state, alg, goal, max_reps=8):
    """Shortest sequence of (U^k then alg) that reaches `goal`."""
    if goal(state):
        return []
    seen = {state}
    q = deque([(state, [])])
    while q:
        st, path = q.popleft()
        if len(path) // 2 >= max_reps:
            continue
        for uk in U_TURNS:
            nxt = cube.apply(st, uk + alg)
            npath = path + [uk, alg]
            if goal(nxt):
                return [m for part in npath for m in part]
            if nxt in seen:
                continue
            seen.add(nxt)
            q.append((nxt, npath))
    raise RuntimeError('no solution for stage')


def auf(state):
    for uk in U_TURNS:
        if cube.apply(state, uk) == cube.SOLVED:
            return uk
    return []


# ------------------------------------------------------------ stage 0

WHITE_DOWN_ROTATION = {
    'D': [], 'U': ['x', 'x'], 'F': ["x'"], 'B': ['x'], 'R': ['z'], 'L': ["z'"],
}


# ------------------------------------------------------------ stage 1  daisy

def petal_faces(state):
    out = []
    for name in slots.U_EDGES:
        s = dict(slots.stickers(state, slots.EDGES[name]))
        if s['U'] == 'D':
            out.append(side_face_of(name)[0])
    return out


def d_edge_solved(state, name):
    return all(c == f for f, c in slots.stickers(state, slots.EDGES[name]))


def white_cross_done(state):
    return all(d_edge_solved(state, n) for n in slots.D_EDGES)


def settled_count(state):
    """White edges that are either a petal on top or already home on the bottom."""
    return len(petal_faces(state)) + sum(1 for n in slots.D_EDGES if d_edge_solved(state, n))


def make_free(sv, face):
    """Rotate U until the petal slot above `face` is empty."""
    for uk in U_TURNS:
        if face not in petal_faces(cube.apply(sv.state, uk)):
            sv.do(uk)
            return
    raise RuntimeError(f'cannot free the petal slot above {face}')


def solve_daisy(sv):
    sv.stage('daisy', 'Make the daisy')
    for _ in range(60):
        if settled_count(sv.state) == 4:
            return
        target = None
        for name, entry in slots.EDGES.items():
            s = dict(slots.stickers(sv.state, entry))
            if 'D' not in s.values():
                continue
            if 'U' in name and s['U'] == 'D':
                continue                      # already a petal
            if 'D' in name and d_edge_solved(sv.state, name):
                continue                      # already home, leave it alone
            target = (name, s)
            break
        if target is None:
            return
        name, s = target
        white_face = [f for f, c in s.items() if c == 'D'][0]

        if 'U' in name:
            # lying on its side in the top layer: knock it into the middle
            sv.do([side_face_of(name)[0]])
        elif 'D' in name:
            face = side_face_of(name)[0]
            make_free(sv, face)
            sv.do([face + '2'] if white_face == 'D' else [face])
        else:
            # middle layer: turn the face NOT carrying white so white lands on top
            other = [f for f in side_face_of(name) if f != white_face][0]
            make_free(sv, other)
            up_slot = [n for n in slots.U_EDGES if other in n][0]
            for turn in [other, other + "'"]:
                probe = cube.apply(sv.state, [turn])
                if dict(slots.stickers(probe, slots.EDGES[up_slot]))['U'] == 'D':
                    sv.do([turn])
                    break
            else:
                raise RuntimeError(f'stuck on middle edge {name}')
    raise RuntimeError('daisy did not converge')


# ------------------------------------------------------------ stage 2  white cross

def solve_white_cross(sv):
    sv.stage('cross', 'Drop the petals into the white cross')
    for _ in range(8):
        chosen = None
        for name in slots.U_EDGES:
            s = dict(slots.stickers(sv.state, slots.EDGES[name]))
            if s['U'] != 'D':
                continue
            chosen = (side_face_of(name)[0], s[side_face_of(name)[0]])
            break
        if chosen is None:
            return
        from_face, colour = chosen
        sv.do(u_turn_moving(from_face, colour))
        sv.do([colour + '2'])


# ------------------------------------------------------------ stage 3  white corners

def d_corner_solved(state, name):
    return all(c == f for f, c in slots.stickers(state, slots.CORNERS[name]))


def solve_first_layer_corners(sv):
    sv.stage('corners', 'Fill in the white corners')
    for _ in range(20):
        unsolved = [n for n in slots.D_CORNERS if not d_corner_solved(sv.state, n)]
        if not unsolved:
            return
        # prefer a corner already waiting in the top layer, and the one
        # needing the least re-gripping, so we avoid pointless round trips
        def cost(name):
            at, _ = slots.find_corner(sv.state, set(name))
            rot = len(y_bringing_pair(side_face_of(name)))
            return (1 if 'D' in at else 0, rot)
        target = min(unsolved, key=cost)
        here, _ = slots.find_corner(sv.state, set(target))
        if 'D' in here:
            sv.do(y_bringing_pair(side_face_of(here)))
            sv.do("R U R'")                   # lift the stuck corner into the top
            continue
        sv.do(y_bringing_pair(side_face_of(target)))
        sv.do(bfs_alg(sv.state, SEXY, lambda st: d_corner_solved(st, 'DFR')))
    raise RuntimeError('white corners did not converge')


# ------------------------------------------------------------ stage 4  middle row

def mid_edge_solved(state, name):
    return all(c == f for f, c in slots.stickers(state, slots.EDGES[name]))


def solve_second_layer(sv):
    sv.stage('second', 'Finish the middle row')
    for _ in range(20):
        unsolved = [n for n in slots.MID_EDGES if not mid_edge_solved(sv.state, n)]
        if not unsolved:
            return
        candidate = None
        for name in slots.U_EDGES:
            s = dict(slots.stickers(sv.state, slots.EDGES[name]))
            if 'U' in s.values():
                continue
            face = side_face_of(name)[0]
            cand = (face, s)
            if candidate is None:
                candidate = cand
            # prefer one that needs no re-grip at all
            if len(u_turn_moving(face, s[face])) + len(y_to_front(s[face])) == 0:
                candidate = cand
                break
        if candidate is None:
            sv.do(y_bringing_pair(list(unsolved[0])))
            sv.do(INSERTR)                    # pop a wrong piece out of the middle
            continue
        face, s = candidate
        front_colour = s[face]
        sv.do(u_turn_moving(face, front_colour))
        sv.do(y_to_front(front_colour))
        # re-read after the rotation, the face letters have all moved
        top = dict(slots.stickers(sv.state, slots.EDGES['UF']))['U']
        sv.do(INSERTR if top == 'R' else INSERTL)
    raise RuntimeError('middle row did not converge')


# ------------------------------------------------------------ stages 5-8  last layer

def top_cross_done(state):
    return all(dict(slots.stickers(state, slots.EDGES[n]))['U'] == 'U'
               for n in slots.U_EDGES)


def top_face_done(state):
    return top_cross_done(state) and all(
        dict(slots.stickers(state, slots.CORNERS[n]))['U'] == 'U'
        for n in slots.U_CORNERS)


def top_corners_placed(state):
    """Every top corner home and still the right way up."""
    return all(all(c == f for f, c in slots.stickers(state, slots.CORNERS[n]))
               for n in slots.U_CORNERS)


def solved_up_to_u(state):
    return any(cube.apply(state, uk) == cube.SOLVED for uk in U_TURNS)


# ------------------------------------------------------------ entry point

def solve(state, white_face='D'):
    sv = Solve(state)
    sv.stage('hold', 'Hold your cube with white on the bottom')
    sv.do(WHITE_DOWN_ROTATION[white_face])
    if not white_cross_done(sv.state):
        solve_daisy(sv)
        solve_white_cross(sv)
    else:
        sv.stage('daisy', 'Make the daisy')
        sv.stage('cross', 'Drop the petals into the white cross')
    solve_first_layer_corners(sv)
    solve_second_layer(sv)
    sv.stage('topcross', 'Make the yellow cross')
    sv.do(bfs_alg(sv.state, CROSS, top_cross_done))
    sv.stage('topface', 'Finish the whole yellow face')
    sv.do(bfs_alg(sv.state, SUNE, top_face_done))
    sv.stage('topcorners', 'Put the last corners in their homes')
    sv.do(bfs_alg(sv.state, APERM, top_corners_placed))
    sv.stage('topedges', 'Slide the last edges home')
    sv.do(bfs_alg(sv.state, UPERM, solved_up_to_u))
    sv.do(auf(sv.state))
    for st in sv.stages:
        st['moves'] = simplify(st['moves'])
    if sv.state != cube.SOLVED:
        raise RuntimeError('solver finished but the cube is not solved')
    return sv


# ------------------------------------------------------------ tidy-up

OPPOSITE_OK = set()


def simplify(moves):
    """Collapse adjacent turns of the same face: U U -> U2, U U' -> nothing."""
    amount = {'': 1, "'": 3, '2': 2}
    suffix = {1: '', 2: '2', 3: "'"}
    out = []
    for m in moves:
        base, suf = m[0], m[1:]
        if out and out[-1][0] == base:
            total = (amount[out[-1][1:]] + amount[suf]) % 4
            out.pop()
            if total:
                out.append(base + suffix[total])
        else:
            out.append(base + suf)
    return out
