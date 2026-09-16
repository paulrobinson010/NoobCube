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


if __name__ == '__main__':
    check()
