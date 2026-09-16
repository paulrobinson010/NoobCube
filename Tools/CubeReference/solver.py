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
CROSS   = "F U R U' R' F'".split()
SUNE    = "R U R' U R U2 R'".split()
APERM   = "R B' R F2 R' B R F2 R2".split()
UPERM   = "F2 U R' L F2 L' R U F2".split()
# The same thing the other way round: both leave the back edge alone and
# send the other three round, one clockwise and one anticlockwise.
UPERM_L = "F2 U' R' L F2 L' R U' F2".split()

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

    def step(self, piece=None, home=None, spin=None, grip=None, turn=None,
             outcome=None, alg_name=None, places=True):
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
            'spin': spin, 'grip': grip, 'turn': turn,
            'outcome': outcome, 'alg_name': alg_name,
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


CENTRES = {f: i * 9 + 4 for i, f in enumerate(cube.FACES)}
FACE_OF = [cube.FACES[i // 9] for i in range(54)]     # which face each sticker belongs to


def follow(index, moves):
    """Where the sticker at `index` ends up after these moves.

    apply_perm reads `state[perm[i]]` into position i, so the sticker at
    perm[i] lands on i: following one forwards is an inverse lookup.
    """
    for m in moves:
        index = cube.MOVES[m].index(index)
    return index


def key_sticker(state, piece):
    """The square on a piece worth watching: its white one if it has one."""
    table = slots.EDGES if len(piece) == 2 else slots.CORNERS
    find = slots.find_edge if len(piece) == 2 else slots.find_corner
    name, stickers = find(state, piece)
    entry = table[name]
    for wanted in ('D', 'U'):
        for (face, colour), (_, index) in zip(stickers, entry):
            if colour == wanted:
                return index
    return entry[0][1]


def marks(state, step, moves):
    """One square to watch, and where these moves put it.

    Always a square that actually moves. A child told to watch something that
    stays still while the cube changes around it learns nothing, which is what
    made the old lining-up steps so baffling.
    """
    if step['piece']:
        start = key_sticker(state, step['piece'])
        end = follow(start, moves)
        if end != start:
            return start, end

    if any(m[0] in 'xyz' for m in moves):
        # The cube itself is turning: watch the middle that ends up facing you.
        front = CENTRES['F']
        for index in CENTRES.values():
            if follow(index, moves) == front and index != front:
                return index, front

    if step['home']:
        # Making room: the square to watch is the one that is in the way.
        start = step['home'][0]
        end = follow(start, moves)
        if end != start:
            return start, end

    # A last-layer algorithm moves several pieces at once. Watch one square
    # that the move actually puts right — the top face first, since that is
    # where the child is looking.
    after = cube.apply_regrip(state, moves)
    order = list(range(9)) + list(range(9, 54))
    for index in order:
        landing = follow(index, moves)
        if (landing != index and state[index] != FACE_OF[index]
                and after[landing] == FACE_OF[landing]):
            return index, landing

    # Nothing is put right by this one — it is setting up the shape for the
    # next go. Watch a square that at least travels somewhere.
    for index in order:
        landing = follow(index, moves)
        if landing != index:
            return index, landing

    return None, None


def slot_name(colours):
    """The slot a piece belongs in, named the way slots.py names them."""
    return ''.join(sorted(colours, key=lambda f: SLOT_ORDER[f]))


def side_face_of(slot_name):
    return [f for f in slot_name if f in SIDE_FACES]


def cross_ready(state):
    """The three shapes the cross move is taught from, and nothing else.

    A dot, an L pointing at the back and the left, or a line lying left to
    right. Letting the search go where it liked meant the app told the child to
    look for one shape and then worked from another. Costs nothing: the same
    1.62 goes on average either way.
    """
    showing = frozenset(n for n in slots.U_EDGES
                        if dict(slots.stickers(state, slots.EDGES[n]))['U'] == 'U')
    return showing in (frozenset(),
                       frozenset({'UB', 'UL'}),
                       frozenset({'UL', 'UR'}))


def fish_ready(state):
    """Where the fish is taught from.

    One corner already yellow on top: that one goes at the front left. None
    yet, or two: the front-left corner has its yellow looking left. Also free,
    at the same 2.25 goes on average.
    """
    up = [n for n in slots.U_CORNERS
          if dict(slots.stickers(state, slots.CORNERS[n]))['U'] == 'U']
    if len(up) == 1:
        return up[0] == 'UFL'
    return dict((c, f) for f, c in slots.stickers(state, slots.CORNERS['UFL'])).get('U') == 'L'


def bfs_alg_rounds(state, alg, goal, max_reps=8, ready=None, also=None):
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
            lined = cube.apply(st, uk)
            if ready is not None and not ready(lined):
                continue
            for a in ([alg] if also is None else [alg, also]):
                nxt = cube.apply(lined, a)
                npath = path + [(uk, a)]
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

        # Every white edge still to do, with what it would cost. The cheapest
        # one is taken, which is what anybody does by eye: an edge already
        # sitting beside a middle needs one turn and nothing else.
        candidates = []
        for name, entry in slots.EDGES.items():
            s_ = dict(slots.stickers(sv.state, entry))
            if 'D' not in s_.values():
                continue
            if 'U' in name and s_['U'] == 'D':
                continue                      # already a petal
            if 'D' in name and d_edge_solved(sv.state, name):
                continue                      # already home, leave it alone
            piece = set(s_.values())
            candidates.append((petal_plan(sv.state, piece), piece))
        if not candidates:
            return

        (moves, petal, setup, _), target = min(candidates, key=lambda c: len(c[0][0]))
        easiest = len(moves) == 1
        sv.step(piece=target, home=petal,
                spin='Spin the top to move this out of the space we need.',
                turn='Turn this side to bring the white square out where we can lift it.',
                outcome=('This one is the easiest — one turn lifts it straight into '
                         'the daisy.') if easiest else
                       'Now one turn lifts it into the daisy, white facing the sky.')
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
                spin='Spin the top until this colour is above the middle that '
                     'matches it.',
                grip='Turn the cube so that side faces you, and check: the colour '
                     'on the petal and the middle underneath must match. If they '
                     'do not, the cube cannot come out right.',
                outcome='Now turn this whole side over twice. The white drops to '
                        'the bottom and the colour stays matched.')
        sv.do(u_turn_moving(from_face, colour))
        # Bring that side to the front so the child can see the match for
        # themselves. Lining the colours up is the whole point of this stage:
        # a cross with the sides wrong looks finished and is not.
        sv.do(y_to_front(colour))
        sv.running()
        sv.do(['F2'])


# ------------------------------------------------------------ stage 3  white corners

def d_corner_solved(state, name):
    return all(c == f for f, c in slots.stickers(state, slots.CORNERS[name]))


def corner_plan(state, name):
    """What it takes to put this corner in, the way it is taught.

    Turn the cube so the gap is at the front right, spin the top until the
    corner is sitting directly over it, then do righty until it drops in. That
    is the whole method: no searching, nothing to work out, and the child can
    check each part by looking at the middles.

    Returns the re-grip, the spin, the moves, and whether it places the corner —
    one stuck in the bottom has to come out first and does not.
    """
    here, _ = slots.find_corner(state, set(name))
    if 'D' in here:
        # No corner is waiting up top, so one has to be lifted out. A whole
        # righty does that just as well as the three moves it starts with —
        # checked on 767 stuck corners — and it keeps the child's whole
        # vocabulary for this stage down to one thing.
        return solver_grip(here), [], SEXY, False

    grip = solver_grip(name)
    after = cube.apply_regrip(state, grip)
    # The gap is now the front-right one, so the corner that belongs there is
    # the one carrying those three colours.
    piece = {'D', 'F', 'R'}
    spin = None
    for uk in U_TURNS:
        at, _ = slots.find_corner(cube.apply(after, uk), piece)
        if at == 'UFR':
            spin = uk
            break
    if spin is None:
        raise RuntimeError(f'cannot bring {name} over its gap')

    working = cube.apply(after, spin)
    moves = []
    for _ in range(6):
        if d_corner_solved(working, 'DFR'):
            break
        working = cube.apply(working, SEXY)
        moves += SEXY
    else:
        raise RuntimeError(f'righty did not drop {name} in')
    return grip, spin, moves, True


def solver_grip(name):
    return y_bringing_pair(side_face_of(name))


def solve_first_layer_corners(sv):
    sv.stage('corners', 'Fill in the white corners')
    for _ in range(20):
        unsolved = [n for n in slots.D_CORNERS if not d_corner_solved(sv.state, n)]
        if not unsolved:
            return

        plans = {n: corner_plan(sv.state, n) for n in unsolved}
        ready = {n: p for n, p in plans.items() if p[3]}
        # Never take a corner out of the bottom while one is waiting to go in.
        choices = ready or plans
        target = min(choices, key=lambda n: sum(len(part) for part in choices[n][:3]))
        grip, spin, moves, places = choices[target]

        if not places:
            # Which of the two ways it is stuck, so the words match what the
            # child is looking at.
            at, _ = slots.find_corner(sv.state, set(target))
            in_its_own_gap = at == target
            sv.step(piece=set(target), home=target, places=False,
                    grip='This one is down in the bottom already. Turn the cube so '
                         'it is at the front right.',
                    outcome=('There is no white corner waiting up top, and this one '
                             'is in its gap facing the wrong way. One righty lifts '
                             'it out, and then we can put it back in properly.')
                            if in_its_own_gap else
                            ('There is no white corner waiting up top, so we have to '
                             'bring one up. One righty lifts this one out, and then '
                             'we can put it in its own gap.'))
            sv.do(grip)
            sv.running()
            sv.do(moves)
            continue

        sv.step(piece=set(target), home=target, alg_name='righty',
                grip='Look at the three middles around this corner\'s gap — those '
                     'are its colours. Turn the cube so that gap is at the front '
                     'right.',
                spin='Spin the top until the corner is sitting directly over its '
                     'gap, so its colours are above the middles that match.',
                outcome=('It is already the right way round — one righty drops it '
                         'straight in.') if len(moves) <= 4 else
                        'Now do righty over and over until it drops in. It only '
                        'goes in the right way round, so it sorts itself out.')
        sv.do(grip)
        sv.do(spin)
        sv.running()
        sv.do(moves)
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
        # Count what each one would cost rather than taking the first that comes
        # to hand. The insert is always the same eight moves, so the difference
        # is entirely in the lining up, and an edge already sitting over the
        # middle that matches it needs none of it.
        candidate, cheapest = None, None
        for name in slots.U_EDGES:
            s = dict(slots.stickers(sv.state, slots.EDGES[name]))
            if 'U' in s.values():
                continue                      # belongs in the last layer
            face = side_face_of(name)[0]
            cost = len(u_turn_moving(face, s[face])) + len(y_to_front(s[face]))
            if cheapest is None or cost < cheapest:
                cheapest, candidate = cost, (face, s)
        if candidate is None:
            stuck = dict(slots.stickers(sv.state, slots.EDGES[unsolved[0]]))
            sv.step(piece=set(stuck.values()), home=slot_name(set(stuck.values())),
                    places=False,
                    grip='This edge is in the middle row but in the wrong place. '
                         'Turn the cube so it is at the front right.',
                    outcome='Sending another edge in pushes this one out to the top.')
            sv.do(y_bringing_pair(list(unsolved[0])))
            sv.running()
            sv.do(INSERTR)                    # pop a wrong piece out of the middle
            continue
        face, s = candidate
        front_colour = s[face]
        piece = set(s.values())
        sv.step(piece=piece, home=slot_name(piece),
                spin='Spin the top until this colour sits on the middle that '
                     'matches it, making a little T.',
                grip='Turn the cube so that side is facing you.',
                outcome=('This one is already lined up — send the top away from the '
                         'gap and it drops in.') if cheapest == 0 else
                        'Send the top away from the gap, and the edge drops in.')
        sv.do(u_turn_moving(face, front_colour))
        sv.do(y_to_front(front_colour))
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

def run_rounds(sv, alg, goal, alg_name, line_up, outcome, ready=None, also=None):
    """One step per round of 'line the top up, then run the one you know'."""
    for turn, moves in bfs_alg_rounds(sv.state, alg, goal, ready=ready, also=also):
        sv.step(alg_name=alg_name, spin=line_up, outcome=outcome)
        sv.do(turn)
        sv.running()
        sv.do(moves)


def runs_of(step):
    """A step, broken into the things it actually asks the child to do.

    Spinning the top and turning the whole cube are different actions with
    different things to look at, so they get a card each. The words for each
    one only exist if its moves do, which is why nothing can claim a turn that
    never happened.
    """
    out = []
    run, kind = [], None
    for move in step['setup']:
        if move[0] in 'xyz':
            this = 'grip'                     # turning the whole cube round
        elif move[0] == 'U':
            this = 'spin'                     # spinning the top layer
        else:
            this = 'turn'                     # turning a side to free a piece
        if kind is not None and this != kind:
            out.append(('position', run, step[kind]))
            run = []
        kind = this
        run.append(move)
    if run:
        out.append(('position', run, step[kind]))
    if step['algorithm']:
        out.append(('move', step['algorithm'], step['outcome']))
    return out


def rename_after(moves):
    """What each face is called after these moves, if any of them turn the cube."""
    spins = [m for m in moves if m[0] in 'xyz']
    if not spins:
        return {f: f for f in cube.FACES}
    rotated = cube.apply(cube.SOLVED, spins)
    return {rotated[index]: face for face, index in CENTRES.items()}


def split_steps(sv, start):
    """Separate getting a piece into position from the move that places it.

    They are two different things and a child needs them kept apart: one is
    spinning the cube or the top until something is where you can work on it,
    the other is the set of moves you have learned. Run together in one
    instruction they read as magic, and the explanation is too long to fit on
    the screen besides.
    """
    state = start
    for stage in sv.stages:
        split = []
        for step in stage['steps']:
            # A step's piece is named in the labels of the moment it was
            # written down, so the renaming only runs from there — not from the
            # start of the solve.
            naming = {f: f for f in cube.FACES}
            for purpose, moves, text in runs_of(step):
                if not moves:
                    continue

                # Everything is read in the labels of the moment, because a
                # re-grip earlier in the same step will have renamed the faces.
                piece = {naming[c] for c in step['piece']} if step['piece'] else None
                here = {'piece': piece, 'home': []}
                if piece:
                    table = slots.EDGES if len(piece) == 2 else slots.CORNERS
                    find = slots.find_edge if len(piece) == 2 else slots.find_corner
                    at, _ = find(state, piece)
                    here['from'] = [i for _, i in table[at]]
                    home_slot = (slot_name(piece)
                                 if step['home_slot'] == slot_name(step['piece'])
                                 else step['home_slot'])
                    here['home_slot'] = home_slot
                    here['home'] = [i for _, i in table[home_slot]]
                else:
                    here['from'] = []
                    here['home_slot'] = None

                marker, target = marks(state, here, moves)
                split.append({
                    'purpose': purpose,
                    'piece': piece,
                    'from': here['from'],
                    'home': here['home'],
                    'home_slot': here['home_slot'],
                    'moves': moves,
                    'setup': moves if purpose == 'position' else [],
                    'algorithm': [] if purpose == 'position' else moves,
                    'line_up': text if purpose == 'position' else None,
                    'outcome': text if purpose == 'move' else None,
                    'text': text,
                    'alg_name': step['alg_name'] if purpose == 'move' else None,
                    'places': step['places'] and purpose == 'move',
                    'marker': marker,
                    'target': target,
                })
                state = cube.apply_regrip(state, moves)
                rename = rename_after(moves)
                naming = {k: rename[v] for k, v in naming.items()}
        stage['steps'] = split


def solve(state, white_face='D'):
    sv = Solve(state)
    sv.stage('hold', 'Hold your cube with white on the bottom')
    sv.step(grip='Turn the whole cube so white is underneath and yellow is on top.',
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
               'Look at the yellow on top. You will see a dot, or a bent L, or a '
               'line. Turn the top until a line lies left to right, or an L points '
               'at the back and the left. A dot can stay where it is. The move only '
               'works from there, which is the whole reason we turn the top first.',
               'The cross move turns a dot into an L, an L into a line, and a line '
               'into the cross. Same six moves every time — it is the shape you '
               'start from that changes.',
               ready=cross_ready)
    sv.stage('topface', 'Finish the whole yellow face')
    run_rounds(sv, SUNE, top_face_done, 'the fish',
               'The fish is one corner with yellow on top and two yellow stickers '
               'beside it, all pointing the same way. Count the corners with yellow '
               'on top: if one has, turn the top until it is the front left one. If '
               'none have, or two have, turn the top until the front left corner has '
               'its yellow looking left. That is where the fish starts.',
               'The fish spins three corners and leaves the fourth alone, so more '
               'yellow comes up each go. Look for the fish again and do it again '
               'until the whole top is yellow.',
               ready=fish_ready)
    sv.stage('topcorners', 'Put the last corners in their homes')
    run_rounds(sv, APERM, top_corners_placed, 'the corner swap',
               'Find the two corners that want to swap and turn the top so they '
               'are where the swap picks them up.',
               'The corner swap trades two corners over, leaving the rest alone.')
    sv.stage('topedges', 'Slide the last edges home')
    run_rounds(sv, UPERM, solved_up_to_u, 'the edge swap',
               'Turn the top so the edge that is already home is at the back. The '
               'other three go round in a circle — one way or the other, whichever '
               'way they need.',
               'Three sides swapping takes one go. All four takes two.',
               also=UPERM_L)
    sv.step(spin='One last spin of the top.',
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
    split_steps(sv, state)
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
