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
    """
    turned = cube.apply(cube.SOLVED, grip)
    return {turned[CENTRE[f]]: f for f in cube.FACES}


def possibilities(cube_state, scanned):
    """Every way the cube could be held: one when it agrees, all 24 when not.

    A cube whose own idea of itself has drifted still reports turns perfectly
    well, so the grip is learned from those instead of given up on.
    """
    hits = [g for g in GRIPS if regripping(cube_state, g) == scanned]
    return hits or list(GRIPS)


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


if __name__ == '__main__':
    check()
    check_through_a_solve()
    check_learning_the_grip()
