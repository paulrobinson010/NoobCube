"""Which way round a smart cube is being held.

The twin of `NoobCube/SmartCube/CubeAlignment.swift`. A smart cube knows its own
faces absolutely — each one has a sensor — but has no idea which way up it is in
the child's hands. So when it says "R" it means *its* right, which need not be
the side the child is being told is the right. Get this wrong and every turn is
read as the wrong face, and a child doing exactly the right thing is told they
are wrong.

The camera settles it: after a scan we know what the cube really looks like, and
the cube can be asked what it thinks it looks like. Same cube, two grips.

    python3 Tools/CubeReference/alignment.py
"""
import random
import cube

CENTRE = {f: i * 9 + 4 for i, f in enumerate(cube.FACES)}


def regripping(state, grip):
    """Turn the cube in your hands: squares move, then centres are renamed."""
    return cube.apply_regrip(state, grip)


def all_grips():
    """The 24 ways to hold a cube: a face on top, then four ways round."""
    grips, seen = [], set()
    for to_top in ([], ['x'], ['x2'], ["x'"], ['z'], ["z'"]):
        for spin in ([], ['y'], ['y2'], ["y'"]):
            grip = to_top + spin
            shape = tuple(cube.apply(cube.SOLVED, grip))
            if shape not in seen:
                seen.add(shape)
                grips.append(grip)
    return grips


GRIPS = all_grips()


def faces_after(grip):
    """What the app calls each face the cube names.

    Read straight off the middles: turn a solved cube by the grip and whatever
    letter is sitting in a place is the face that moved there.

    **A raw `apply`, never `apply_regrip`.** Regripping renames the faces after
    a rotation so that a solved cube still reads as solved — which is right for
    solving and fatal here, because then a solved cube turned any way round
    comes back solved, every centre reads as its own face, and this map is the
    identity for all twenty-four grips. The Swift did exactly that for a long
    time, so no turn was ever renamed and every one came out as the opposite
    side. ``check_the_grips_are_all_different`` is here so that cannot happen
    again quietly.
    """
    turned = cube.apply(cube.SOLVED, grip)
    return {turned[CENTRE[f]]: f for f in cube.FACES}


def check_the_grips_are_all_different():
    """Twenty-four ways of holding a cube, twenty-four different face maps.

    If they ever collapse into one, every turn is read in the cube's own frame
    and nothing built on top of them means anything — not matching off the
    middles, not the way the child is asked to hold it, none of it.
    """
    maps = [tuple(faces_after(g)[f] for f in cube.FACES) for g in GRIPS]
    identity = tuple(cube.FACES)
    print('ways of holding a cube          %d' % len(maps))
    print('  face maps that differ         %d' % len(set(maps)))
    print('  of those, the identity        %d' % sum(1 for m in maps if m == identity))
    assert len(set(maps)) == 24, 'the grips have collapsed into each other'
    assert sum(1 for m in maps if m == identity) == 1
    # And the one the app leans on is not the identity.
    asked, _ = as_the_child_is_asked_to_hold_it()
    assert faces_after(asked) != dict(zip(cube.FACES, cube.FACES))
    print('  the way they are asked to hold it is not one of them')
    print('ALL PASS')


def check_the_grips_are_told_apart_by_their_middles():
    """How the twenty-four are told apart from one another, which is the whole
    ballgame.

    The app built this list by turning a solved cube each way and throwing away
    the ways that gave the same result. But the app's own ``applying`` renames
    the faces after a rotation, so that a solved cube still reads as solved --
    right for solving, and fatal here. Every one of the twenty-four came back
    *solved*, twenty-three were thrown away as duplicates, and the list held
    exactly one way of holding a cube: the identity.

    Everything downstream then quietly stopped working while looking fine. The
    way the child is asked to hold the cube could not be found in a list that
    did not contain it, so it fell back to the identity. Lining up off the
    middles found nothing. Throwing the grip away and learning it again from
    the turns re-opened a single candidate, so it was "settled" on the identity
    the instant it was re-opened. And every turn was read in the cube's own
    frame -- half a turn from the hand holding it, which is every "it turns the
    opposite side" that was ever reported.

    This twin has always used the raw ``apply`` here, so it could never have
    caught it by agreeing or disagreeing. So the trap itself is the test.
    """
    naive = set()
    for to_top in ([], ['x'], ['x2'], ["x'"], ['z'], ["z'"]):
        for spin in ([], ['y'], ['y2'], ["y'"]):
            naive.add(cube.apply_regrip(cube.SOLVED, to_top + spin))
    print('told apart by where the middles land            %d' % len(GRIPS))
    print('  told apart by a solved cube turned and renamed  %d' % len(naive))
    assert len(GRIPS) == 24, len(GRIPS)
    assert len(naive) == 1, (
        'renaming after a rotation should make all 24 look identical; if this '
        'ever stops being true the warning below is stale')
    print('  so a solved cube can never tell two of them apart')
    print('ALL PASS')


def from_the_middles(centres_seen):
    """Where the cube's own faces have got to, read straight off the middles.

    Not a search and not a guess. A cube's middles never move relative to one
    another, so the face the cube calls R is its red one for ever, and the
    answer is whichever face the camera found red on.

    It matters that this does not look at where the *pieces* are. Lining up by
    position fails exactly when the cube's idea of where its pieces are has
    drifted — which is the reason anyone reaches for the camera — so it failed
    in the one case it was needed.
    """
    where = {colour: face for face, colour in centres_seen.items()}
    if len(where) != len(cube.FACES):
        return None
    want = {f: where[CUBE_FRAME[f]] for f in cube.FACES}
    return next((g for g in GRIPS if faces_after(g) == want), None)


def check_the_middles_are_enough(trials=500, seed=11):
    """However the cube is held, and whatever it believes about itself."""
    rng = random.Random(seed)
    gave_up = right = 0
    for _ in range(trials):
        # However they happened to hold it for the scan.
        held = rng.choice(GRIPS)
        centres = {faces_after(held)[f]: CUBE_FRAME[f] for f in cube.FACES}
        truth = from_the_middles(centres)
        assert faces_after(truth) == faces_after(held)

        # And a cube whose own idea of itself has drifted.
        scanned = cube.apply(cube.SOLVED, scramble(rng))
        drifted = cube.apply(regripping(scanned, truth),
                             [rng.choice(['R', 'U', "F'", 'L2', 'B', 'D2'])])

        how, _ = matching(drifted, scanned)
        gave_up += how == 'disagrees'
        right += faces_after(from_the_middles(centres)) == faces_after(truth)

    print('cubes whose reported position was wrong  %d' % trials)
    print('  lining up by position gave up          %d' % gave_up)
    print('  lining up off the middles was right    %d' % right)
    assert gave_up == trials and right == trials
    print('ALL PASS')


def likeliest_first(candidates):
    """The way they were asked to hold it, at the front.

    Which one is first is not a detail: a turn that cannot be narrowed — before
    anything has been asked for, or when they turn something else — is read
    with the first one.
    """
    asked, _ = as_the_child_is_asked_to_hold_it()
    want = faces_after(asked)
    return ([g for g in candidates if faces_after(g) == want]
            + [g for g in candidates if faces_after(g) != want])


def possibilities(cube_state, scanned):
    """Every way the cube could be held: one when it agrees, all 24 when not.

    A cube whose own idea of itself has drifted still reports turns perfectly
    well, so the grip is learned from those instead of given up on.
    """
    hits = [g for g in GRIPS if regripping(cube_state, g) == scanned]
    return likeliest_first(hits or list(GRIPS))


def matching(cube_state, scanned):
    """('found', grip) | ('too symmetric', None) | ('disagrees', None)"""
    hits = [g for g in GRIPS if regripping(cube_state, g) == scanned]
    if not hits:
        return 'disagrees', None
    if len(hits) > 1:
        return 'too symmetric', None
    return 'found', hits[0]


def app_move(grip, cube_move):
    """A turn the cube names, said in the app's words."""
    return faces_after(grip)[cube_move[0]] + cube_move[1:]


# ------------------------------------------------------------------ checking

def scramble(rng, length=25):
    faces = ['U', 'D', 'F', 'B', 'R', 'L']
    moves, last = [], None
    for _ in range(length):
        f = rng.choice([x for x in faces if x != last])
        last = f
        moves.append(f + rng.choice(['', "'", '2']))
    return moves


def check(trials=60):
    rng = random.Random(31)
    assert len(GRIPS) == 24, len(GRIPS)

    recovered = renamed = regripped = 0
    for _ in range(trials):
        scanned = cube.apply(cube.SOLVED, scramble(rng))
        for grip in GRIPS:
            seen_by_cube = regripping(scanned, grip)
            how, found = matching(seen_by_cube, scanned)
            assert how == 'found', how
            assert regripping(seen_by_cube, found) == scanned
            recovered += 1

            # Every turn the cube can report must come out as the turn the
            # child was actually asked for.
            for face in cube.FACES:
                for suffix in ('', "'", '2'):
                    theirs = face + suffix
                    ours = app_move(found, theirs)
                    assert (regripping(cube.apply(seen_by_cube, [theirs]), found)
                            == cube.apply(scanned, [ours])), (grip, theirs)
                    renamed += 1

            # The plan turns the whole cube; the cube does not feel it. The
            # grip has to move with the child or everything after the first
            # rotation is read as the wrong face.
            for spin in ('x', "x'", 'x2', 'y', "y'", 'y2', 'z', "z'", 'z2'):
                after = found + [spin]
                assert faces_after(after) == {
                    f: faces_after([spin])[faces_after(found)[f]] for f in cube.FACES}
                assert regripping(seen_by_cube, after) == regripping(scanned, [spin])
                regripped += 1

    # A solved cube looks the same every way round, so no grip can be picked.
    assert matching(cube.SOLVED, cube.SOLVED)[0] == 'too symmetric'
    # A cube whose own idea of itself has drifted must be caught, not guessed at.
    scanned = cube.apply(cube.SOLVED, scramble(rng))
    assert matching(cube.apply(scanned, ['R']), scanned)[0] == 'disagrees'

    print('grips recovered      ', recovered)
    print('turns renamed        ', renamed)
    print('re-grips composed    ', regripped)
    print('ALL PASS')


def check_through_a_solve(trials=120):
    """The same thing, but along a real solve rather than in the abstract.

    The plan turns the whole cube as it goes, and a smart cube cannot feel that
    happen. When the app is waiting on one of those and a layer turn arrives
    instead, it takes the rotation as done and reads the layer turn with the
    rotation counted. This checks the move it then believes was made is the move
    that was made — including, especially, the ones that land straight after a
    rotation, which is where getting the order wrong would show.
    """
    import solver
    import verify_steps

    rng = random.Random(3)
    checked = after_a_spin = 0

    for _ in range(trials):
        start = cube.apply(cube.SOLVED, verify_steps.scramble(rng))
        moves = solver.solve(start).all_moves()

        # The cube's own frame, fixed by its hardware, taken at random.
        grip = rng.choice(GRIPS)
        how, base = matching(regripping(start, grip), start)
        assert how == 'found'

        done = []
        for index, move in enumerate(moves):
            if move[0] in 'xyz':
                done.append(move)
                continue

            # The child is holding it however the plan has turned it by now.
            here = base + [m for m in done if m[0] in 'xyz']
            faces = faces_after(here)
            # So the cube reports this turn as whichever of its own faces that is.
            theirs = next(f for f in cube.FACES if faces[f] == move[0]) + move[1:]

            assert app_move(here, theirs) == move, (index, move)
            checked += 1
            if index and moves[index - 1][0] in 'xyz':
                after_a_spin += 1
            done.append(move)

    print('turns read back along a solve', checked)
    print('  of those, straight after a spin', after_a_spin)
    print('ALL PASS')


def check_learning_the_grip(trials=300):
    """When the cube's own position is wrong, the turns still give the grip.

    The app knows which move it asked for. Every way of holding the cube that
    would have made the reported turn *be* that move survives; the rest are
    ruled out. The survivors all agree on what the turn was — that is what put
    them in the set — so the move can be acted on while the grip comes down.
    """
    import solver
    import verify_steps
    import statistics

    rng = random.Random(5)
    settled_after, never = [], 0

    for _ in range(trials):
        start = cube.apply(cube.SOLVED, verify_steps.scramble(rng))
        moves = solver.solve(start).all_moves()
        truth = rng.choice(GRIPS)              # how it is really being held

        # Nothing is known: the cube's own position disagreed with the scan.
        candidates, done, settled = list(GRIPS), [], None

        for move in moves:
            if move[0] in 'xyz':
                # A whole-cube turn moves the app's frame, so every candidate
                # moves with it — including the real one.
                candidates = [g + [move] for g in candidates]
                truth = truth + [move]
                done.append(move)
                continue

            faces = faces_after(truth)
            theirs = next(f for f in cube.FACES if faces[f] == move[0]) + move[1:]

            fits = [g for g in candidates if app_move(g, theirs) == move]
            assert fits, 'the true grip must always survive'
            assert all(app_move(g, theirs) == move for g in fits), \
                'every survivor must read the turn the same way'
            candidates = fits
            done.append(move)
            if settled is None and len(candidates) == 1:
                settled = len([m for m in done if m[0] not in 'xyz'])

        if settled is None:
            never += 1
        else:
            settled_after.append(settled)

    print('grip settled after (turns)  median %d, 90th %d, worst %d'
          % (statistics.median(settled_after),
             sorted(settled_after)[int(0.9 * len(settled_after))],
             max(settled_after)))
    print('never settled              ', never)
    assert never == 0
    print('ALL PASS')


# ------------------------------------------- how the cube's frame sits in a hand

# What a smart cube's own face numbers mean. Confirmed by asking one: eight
# turns, each named by colour so that how it was held could not come into it.
CUBE_FRAME = {'U': 'white', 'R': 'red', 'F': 'green',
              'D': 'yellow', 'L': 'orange', 'B': 'blue'}

# What the app asks the child for: yellow on top, white underneath, green at
# the front.
CHILD_FRAME = {'U': 'yellow', 'R': 'orange', 'F': 'green',
               'D': 'white', 'L': 'red', 'B': 'blue'}


def as_the_child_is_asked_to_hold_it():
    """The grip between the two, worked out from the colours rather than typed."""
    where = {colour: face for face, colour in CHILD_FRAME.items()}
    want = {f: where[CUBE_FRAME[f]] for f in cube.FACES}
    for grip in GRIPS:
        if faces_after(grip) == want:
            return grip, want
    raise RuntimeError('the two colour schemes are not a way of holding a cube')


def check_the_frame_the_child_holds_it_in(trials=200, seed=5):
    """The bug that survived six rounds of looking elsewhere.

    The cube numbers its faces white-on-top; the child is asked to hold theirs
    yellow-on-top. Those are half a turn apart, so reading a turn as though the
    two frames were the same is wrong on four faces out of six — top and bottom
    swapped, left and right swapped, front and back alone. Which is exactly and
    only what "it turns the opposite side" ever was.
    """
    grip, want = as_the_child_is_asked_to_hold_it()
    print('the cube is held', grip, 'from the frame it numbers its faces in')
    for f in cube.FACES:
        assert CUBE_FRAME[f] == CHILD_FRAME[want[f]], f
    print('  every colour keeps its place across it')
    print('  ' + '  '.join('%s->%s' % (f, want[f]) for f in cube.FACES))

    rng = random.Random(seed)
    checked = 0
    for _ in range(trials):
        scrambled = cube.apply(cube.SOLVED, scramble(rng))
        for face in cube.FACES:
            for suffix in ('', "'", '2'):
                theirs = face + suffix
                ours = app_move(grip, theirs)
                assert (regripping(cube.apply(scrambled, [theirs]), grip)
                        == cube.apply(regripping(scrambled, grip), [ours]))
                checked += 1
    print('  turns renamed through it and checked  %d' % checked)
    assert app_move(grip, 'R') == 'L' and app_move(grip, 'U') == 'D'
    print('  a turn of the red face is a turn of their left')
    print('ALL PASS')


def check_a_cube_that_disagrees_is_still_read_right(trials=200, seed=3):
    """The case a child is most likely to be in.

    They connect a cube, the picture does not match, so they show it to the
    camera. A cube whose own idea of itself is wrong is exactly the case where
    no grip fits and all twenty-four come back — and the first of those is what
    a turn is read with until something narrows it. It used to be the cube's
    own frame, which is half a turn from the hand holding it, so every such
    turn came out as the opposite side.
    """
    rng = random.Random(seed)
    asked, _ = as_the_child_is_asked_to_hold_it()
    checked = 0
    for _ in range(trials):
        scanned = cube.apply(cube.SOLVED, scramble(rng))
        agreeing = regripping(scanned, asked)
        drifted = cube.apply(agreeing, [rng.choice(['R', 'U', "F'", 'L2'])])

        how, _ = matching(drifted, scanned)
        assert how == 'disagrees', how
        candidates = possibilities(drifted, scanned)
        assert len(candidates) == 24
        assert faces_after(candidates[0]) == faces_after(asked), \
            'the way they were asked to hold it must be read first'
        for face in cube.FACES:
            assert app_move(candidates[0], face) == app_move(asked, face)
            checked += 1

    print('a cube that disagrees with the scan, read with the first candidate')
    print('  turns read the way they are holding it  %d' % checked)
    print('  a turn of the cube red face is a turn of their left')
    print('ALL PASS')


if __name__ == '__main__':
    check()
    check_through_a_solve()
    check_learning_the_grip()
    print()
    check_the_frame_the_child_holds_it_in()
    print()
    check_a_cube_that_disagrees_is_still_read_right()
    print()
    check_the_middles_are_enough()
    print()
    check_the_grips_are_all_different()
    print()
    check_the_grips_are_told_apart_by_their_middles()
