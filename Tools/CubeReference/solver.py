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
    """Builds the plan, as stages made of steps.

    A step is one piece being put where it belongs, which is the unit the
    method is actually taught in: *this* piece, into *that* gap, by lining it
    up and then running a set of moves you already know. The moves on their own
    are a recipe to copy; the steps are the thing a child can still do
    tomorrow without the app.
    """

    def __init__(self, state):
        self.state = state
        self.stages = []
        self._current = None
        self._step = None

    def stage(self, key, title):
        self._current = {'key': key, 'title': title, 'moves': [], 'steps': []}
        self.stages.append(self._current)
        self._step = None

    def step(self, piece=None, home=None, line_up=None, outcome=None, alg_name=None,
             places=True):
        """Open a new step: which piece, where it is going, and why.

        `piece` is the set of colours (face letters) that names the piece;
        `home` is the slot it belongs in, in today's labels. Both are read
        before any of the step's moves run, so the sticker positions are the
        ones on screen when the child is being told about it.
        """
        entry = {
            'piece': set(piece) if piece else None,
            'from': [], 'home': [], 'home_slot': home, 'moves': [],
            'setup': [], 'algorithm': [],
            'line_up': line_up, 'outcome': outcome, 'alg_name': alg_name,
            # False for a step that only gets a piece out of the way, so that
            # nothing claims to have finished something it has not.
            'places': places and piece is not None,
            'phase': 'setup',
        }
        if piece:
            table = slots.EDGES if len(piece) == 2 else slots.CORNERS
            finder = slots.find_edge if len(piece) == 2 else slots.find_corner
            at, _ = finder(self.state, set(piece))
            entry['from'] = [i for _, i in table[at]]
            if home:
                entry['home'] = [i for _, i in table[home]]
        self._step = entry
        self._current['steps'].append(entry)

    def running(self):
        """From here on the moves are the algorithm, not the lining up."""
        if self._step:
            self._step['phase'] = 'algorithm'

    def do(self, seq):
        if isinstance(seq, str):
            seq = seq.split()
        if not seq:
            return
        self.state = cube.apply_regrip(self.state, seq)
        self._current['moves'].extend(seq)
        if self._step is None:
            self.step()
        self._step['moves'].extend(seq)
        self._step[self._step['phase']].extend(seq)

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


SLOT_ORDER = {'U': 0, 'D': 1, 'F': 2, 'B': 3, 'R': 4, 'L': 5}


def line_up_text(moves, spin='', grip='', ready='This one is already lined up.'):
    """Describe the lining up in terms of what it actually turned out to be.

    A step that needed no spinning should not be told to spin. Mirrors
    BeginnerSolver.lineUpText in the app.
    """
    spun = any(m[0] == 'U' for m in moves)
    gripped = any(m[0] in 'xyz' for m in moves)
    parts = [p for p, on in ((spin, spun), (grip, gripped)) if on and p]
    return ' '.join(parts) if parts else ready


def slot_name(colours):
    """The slot a piece belongs in, named the way slots.py names them."""
    return ''.join(sorted(colours, key=lambda f: SLOT_ORDER[f]))


def side_face_of(slot_name):
    return [f for f in slot_name if f in SIDE_FACES]


def bfs_alg_rounds(state, alg, goal, max_reps=8):
    """Shortest sequence of (U^k then alg) that reaches `goal`, as rounds.

    Kept as rounds rather than one flat list because a round is what the method
    teaches: line the top up, then run the one set of moves you know.
    """
    if goal(state):
        return []
    seen = {state}
    q = deque([(state, [])])
    while q:
        st, path = q.popleft()
        if len(path) >= max_reps:
            continue
        for uk in U_TURNS:
            nxt = cube.apply(st, uk + alg)
            npath = path + [(uk, alg)]
            if goal(nxt):
                return npath
            if nxt in seen:
                continue
            seen.add(nxt)
            q.append((nxt, npath))
    raise RuntimeError('no solution for stage')


def bfs_alg(state, alg, goal, max_reps=8):
    rounds = bfs_alg_rounds(state, alg, goal, max_reps)
    return [m for turn, a in rounds for m in (turn + a)]


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


def room_above(state, face):
    """U turns that empty the petal slot above `face`, so a turn of that face
    cannot knock an existing petal out. Turning the top never costs a petal."""
    for uk in U_TURNS:
        if face not in petal_faces(cube.apply(state, uk)):
            return uk
    raise RuntimeError(f'cannot free the petal slot above {face}')


def petal_plan(state, piece):
    """Everything it takes to bring one white edge up into the daisy.

    One edge, one plan, however awkwardly it happens to be sitting. It used to
    take two goes for an edge lying on its side — one to knock it out of the
    way and another to lift it — which meant the app announced a piece, moved
    something else, and announced the same piece again. A child cannot follow
    that, and it isn't how anybody teaches the daisy.

    Returns the moves, the petal slot it ends up in, and how many moves at the
    front are lining up rather than lifting.
    """
    moves = []
    working = state

    def look():
        name, stickers = slots.find_edge(working, piece)
        s = dict(stickers)
        return name, s, [f for f, c in s.items() if c == 'D'][0]

    name, s, white_face = look()
    prepared = False

    if 'U' in name and s['U'] != 'D':
        # Lying on its side up top. Knock it down into the middle row, where it
        # can be lifted back up the right way round. Nothing else is up there
        # to disturb: this slot is the one it is in.
        turn = [side_face_of(name)[0]]
        moves += turn
        working = cube.apply(working, turn)
        name, s, white_face = look()
        prepared = True

    if 'D' in name and white_face != 'D':
        # In the bottom but lying on its side, so it cannot come straight up.
        face = side_face_of(name)[0]
        turn = room_above(working, face) + [face]
        moves += turn
        working = cube.apply(working, turn)
        name, s, white_face = look()
        prepared = True

    # Where it is going, and how it gets there.
    if 'D' in name:
        face = side_face_of(name)[0]
        lift = [face + '2']
    else:
        face = [f for f in side_face_of(name) if f != white_face][0]
        lift = None
    petal = slot_name({'U', face})

    clear = room_above(working, face)
    moves += clear
    working = cube.apply(working, clear)

    if lift is None:
        # It has to be *this* edge that arrives white-side-up. Asking only
        # whether the slot shows white lets another white edge answer for it,
        # and then the turn is the wrong way round.
        for turn in [face, face + "'"]:
            probe = cube.apply(working, [turn])
            where, stickers = slots.find_edge(probe, piece)
            if where == petal and dict(stickers)['U'] == 'D':
                lift = [turn]
                break
        else:
            raise RuntimeError(f'cannot lift {piece} into the daisy')

    moves += lift
    return moves, petal, len(moves) - len(lift), prepared


def solve_daisy(sv):
    sv.stage('daisy', 'Make the daisy')
    for _ in range(8):
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
            target = set(s.values())
            break
        if target is None:
            return

        moves, petal, setup, _ = petal_plan(sv.state, target)
        # The wording follows the moves: a step that spun nothing must not say
        # it did.
        lining_up = moves[:setup]
        parts = []
        if any(m[0] != 'U' for m in lining_up):
            parts.append("This one is lying on its side, so first it is turned out "
                         "where we can reach it.")
        if any(m[0] == 'U' for m in lining_up):
            parts.append("Spin the top so the space next to the yellow middle is empty.")
        sv.step(piece=target, home=petal,
                line_up=' '.join(parts) or None,
                outcome='Then one turn lifts it up into the daisy, white facing the sky.')
        sv.do(moves[:setup])
        sv.running()
        sv.do(moves[setup:])
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
            face = side_face_of(name)[0]
            chosen = (face, s[face], set(s.values()))
            break
        if chosen is None:
            return
        from_face, colour, piece = chosen
        sv.step(piece=piece, home=slot_name(piece),
                line_up='Spin the top until this petal\'s side colour is right '
                        'above the middle that matches it.',
                outcome='Then turn that whole side over twice, and the white '
                        'drops down into the cross with its side colour already right.')
        sv.do(u_turn_moving(from_face, colour))
        sv.running()
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
            sv.step(piece=set(target), home=target, places=False,
                    line_up='This corner is already in the bottom, but the wrong '
                            'way round. Turn the cube so it is at the front right.',
                    outcome='One shuffle lifts it out into the top, and then we '
                            'can put it in properly.')
            sv.do(y_bringing_pair(side_face_of(here)))
            sv.running()
            sv.do("R U R'")                   # lift the stuck corner into the top
            continue
        sv.step(piece=set(target), home=target, alg_name='the shuffle',
                line_up='Turn the cube so this corner\'s gap is at the front '
                        'right, then spin the top until the corner is sitting '
                        'directly above it.',
                outcome='Then shuffle until it drops in. It only goes in when it '
                        'is the right way round, so keep going and it sorts itself out.')
        sv.do(y_bringing_pair(side_face_of(target)))
        sv.running()
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
            stuck = dict(slots.stickers(sv.state, slots.EDGES[unsolved[0]]))
            sv.step(piece=set(stuck.values()), home=slot_name(set(stuck.values())),
                    places=False,
                    line_up='Every edge we still need is stuck in the middle row '
                            'already, in the wrong place. Turn the cube so one of '
                            'them is at the front right.',
                    outcome='Sending another edge in pushes this one out into the '
                            'top, where we can aim it properly.')
            sv.do(y_bringing_pair(list(unsolved[0])))
            sv.running()
            sv.do(INSERTR)                    # pop a wrong piece out of the middle
            continue
        face, s = candidate
        front_colour = s[face]
        piece = set(s.values())
        sv.step(piece=piece, home=slot_name(piece),
                outcome='Now send the top away from the gap it needs to go into. '
                        'That opens the gap, drops the edge in, and puts everything '
                        'else back where it was.')
        spin = u_turn_moving(face, front_colour)
        grip = y_to_front(front_colour)
        sv.do(spin)
        sv.do(grip)
        sv._step['line_up'] = line_up_text(
            spin + grip,
            spin='Spin the top until this edge\'s front colour sits right on top of '
                 'the middle that matches it, making a little T.',
            grip='Turn the cube so that side is facing you.',
            ready='This one is already lined up and facing you.')
        # re-read after the rotation, the face letters have all moved
        top = dict(slots.stickers(sv.state, slots.EDGES['UF']))['U']
        sv.running()
        if top == 'R':
            sv._step['alg_name'] = 'send it right'
            sv.do(INSERTR)
        else:
            sv._step['alg_name'] = 'send it left'
            sv.do(INSERTL)
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

def run_rounds(sv, alg, goal, alg_name, line_up, outcome):
    """One step per round of 'line the top up, then run the one you know'."""
    for turn, moves in bfs_alg_rounds(sv.state, alg, goal):
        sv.step(alg_name=alg_name, line_up=line_up if turn else None, outcome=outcome)
        sv.do(turn)
        sv.running()
        sv.do(moves)


def solve(state, white_face='D'):
    sv = Solve(state)
    sv.stage('hold', 'Hold your cube with white on the bottom')
    sv.step(line_up='Turn the whole cube so white is underneath and yellow is on top.',
            outcome='Now left and right mean the same thing to both of us.')
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
    run_rounds(sv, CROSS, top_cross_done, 'the cross move',
               'Turn the top until the yellow shape is pointing the right way: '
               'the two yellow edges at the back and on the left.',
               'Then the cross move turns a dot into an L, an L into a line, and '
               'a line into the whole cross.')
    sv.stage('topface', 'Finish the whole yellow face')
    run_rounds(sv, SUNE, top_face_done, 'the fish',
               'Turn the top until the fish is looking the right way — yellow on '
               'the left of the front face.',
               'Then the fish spins three corners at once. Do it again from the '
               'new shape until the whole top is yellow.')
    sv.stage('topcorners', 'Put the last corners in their homes')
    run_rounds(sv, APERM, top_corners_placed, 'the corner swap',
               'Find the two corners that want to swap and turn the top so they '
               'are where the swap picks them up.',
               'The corner swap trades two corners over, leaving the rest alone.')
    sv.stage('topedges', 'Slide the last edges home')
    run_rounds(sv, UPERM, solved_up_to_u, 'the edge swap',
               'Turn the top so the edge that is already right is at the back.',
               'The edge swap slides the other three round in a circle.')
    sv.step(line_up='One last spin of the top.',
            outcome='And that is the whole cube.')
    sv.do(auf(sv.state))
    # Tidy each step on its own: collapsing turns across a step boundary would
    # blur the very thing the steps are there to show.
    for st in sv.stages:
        for step in st['steps']:
            step['setup'] = simplify(step['setup'])
            step['algorithm'] = simplify(step['algorithm'])
            step['moves'] = step['setup'] + step['algorithm']
        st['steps'] = [step for step in st['steps'] if step['moves']]
        st['moves'] = [m for step in st['steps'] for m in step['moves']]
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
