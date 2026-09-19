"""What a smart cube's move messages actually mean.

The twin of `NoobCube/SmartCube/SmartCubeDialect.swift` and
`Move.between(_:and:)`.

A GAN cube does not send "R". It sends a number for the face and a bit for the
direction, and which number means which face is a detail of firmware GAN have
never published. The app used to carry a hand-written table for it. If that
table is wrong for the cube in your hands, nothing anywhere in the app can
notice — and a wrong table need not even be a *possible* way of labelling a
cube, in which case no way of holding the cube can undo it and every turn is
read as the wrong face for ever.

So nothing is assumed. The cube reports its own position as well as its moves,
and one turn either side of a position report says exactly what that turn was.

    python3 Tools/CubeReference/dialect.py
"""
import collections
import random
import statistics

import cube
import solver
import verify_steps

FACES = list('URFDLB')
EVERY_FACE_TURN = [f + s for f in FACES for s in ('', "'", '2')]


def move_between(before, after):
    """Which single turn took the cube from one position to the other.

    There is never more than one answer. A face turn moves twenty stickers and
    no two of the eighteen possible turns move them the same way, so looking for
    the one that fits is not a guess, it is arithmetic.
    """
    hits = [m for m in EVERY_FACE_TURN if cube.apply(before, [m]) == after]
    return hits[0] if len(hits) == 1 else None


class Dialect:
    """What this cube's own words for its faces turned out to mean."""

    def __init__(self):
        self.meanings = {}          # label -> (face, clockwise is reversed)

    def move(self, label, clockwise):
        if label not in self.meanings:
            return None
        face, reversed_ = self.meanings[label]
        turned = (not clockwise) if reversed_ else clockwise
        return face if turned else face + "'"

    def learn(self, label, clockwise, was):
        if was.endswith('2') or was[0] not in FACES:
            return
        self.meanings[label] = (was[0], (not was.endswith("'")) != clockwise)


# ------------------------------------------------------------------ a cube

def some_firmware(rng):
    """A cube whose six labels mean the six faces in some order, and whose idea
    of clockwise may be the other way round."""
    meaning = FACES[:]
    rng.shuffle(meaning)
    return {f: i for i, f in enumerate(meaning)}, rng.choice([False, True])


def quarters(move):
    """These cubes send a half turn as two quarter turns."""
    return [move[0], move[0]] if move.endswith('2') else [move]


# ------------------------------------------------------------------ checking

def check_a_move_is_recoverable(trials=400, seed=4):
    rng = random.Random(seed)
    total = wrong = ambiguous = 0
    for _ in range(trials):
        start = cube.apply(cube.SOLVED, verify_steps.scramble(rng))
        here = start
        for m in solver.solve(start).all_moves():
            if m[0] in 'xyz':
                here = cube.apply(here, [m])
                continue
            after = cube.apply(here, [m])
            got = move_between(here, after)
            total += 1
            if got is None:
                ambiguous += 1
            elif got != m:
                wrong += 1
            here = after
    print('a turn read back from the positions either side of it')
    print('  turns      %6d' % total)
    print('  wrong      %6d' % wrong)
    print('  ambiguous  %6d' % ambiguous)
    assert wrong == 0 and ambiguous == 0
    print('  ALL PASS')


def check_the_dialect_is_learned(trials=300, seed=7):
    """A whole solve on a cube whose labels are shuffled at random.

    When a label turns up that has not been met, the cube is asked where it is
    and the answer says what the turn was. Compared against naming it from a
    fixed table, which is what the app used to do.
    """
    learned_misreads = table_misreads = total = 0
    questions, faces_used = [], []

    rng = random.Random(seed)
    for _ in range(trials):
        label_of, flipped = some_firmware(rng)
        start = cube.apply(cube.SOLVED, verify_steps.scramble(rng))
        moves = [m for m in solver.solve(start).all_moves() if m[0] not in 'xyz']

        dialect, asked = Dialect(), 0
        here = start
        for m in moves:
            for quarter in quarters(m):
                label = label_of[quarter[0]]
                wire = (not quarter.endswith("'")) != flipped
                after = cube.apply(here, [quarter])
                total += 1

                # What the app used to do: name it from a table, whatever the
                # cube meant. The table is right for one firmware in 1,440.
                if (FACES[label] if wire else FACES[label] + "'") != quarter:
                    table_misreads += 1

                # What it does now.
                read = dialect.move(label, wire)
                if read is None:
                    asked += 1
                    read = move_between(here, after)
                if read != quarter:
                    learned_misreads += 1
                dialect.learn(label, wire, move_between(here, after))
                here = after

        questions.append(asked)
        faces_used.append(len(dialect.meanings))

    print("a solve on a cube whose labels are anybody's guess")
    print('  turns                              %6d' % total)
    print('  read wrongly, from a fixed table   %6d' % table_misreads)
    print('  read wrongly, asking the cube      %6d' % learned_misreads)
    print('  times the cube had to be asked     median %d, worst %d'
          % (statistics.median(questions), max(questions)))
    print('  faces a solve turns at all         median %d, worst %d'
          % (statistics.median(faces_used), max(faces_used)))
    assert learned_misreads == 0
    assert table_misreads > 0
    print('  ALL PASS')


def check_a_wrong_table_need_not_be_a_cube():
    """Why the grip machinery could never have rescued this.

    Holding a cube differently permutes its faces, but only in the twenty-four
    ways a cube can actually be turned. A mistaken table is drawn from all 720
    orderings of six labels. Of those, 48 keep opposite faces opposite — but
    half of *those* are mirror images, which no amount of turning a cube will
    produce. So a grip can undo 24 of 720 mistakes, and for the other 696 no way
    of holding the cube fits, which is what left the app telling a child they
    turned the wrong side over and over without ever settling.
    """
    import itertools
    import alignment

    # The real thing: the face maps of the twenty-four ways to hold a cube.
    holdable = {tuple(alignment.faces_after(g)[f] for f in FACES)
                for g in alignment.GRIPS}

    opposite = {'U': 'D', 'D': 'U', 'R': 'L', 'L': 'R', 'F': 'B', 'B': 'F'}
    keeps_opposites = 0
    for order in itertools.permutations(FACES):
        table = dict(zip(FACES, order))
        if all(table[opposite[f]] == opposite[table[f]] for f in FACES):
            keeps_opposites += 1

    total = 720
    print('ways six labels could be ordered              %d' % total)
    print('  of those, opposite faces still opposite     %d' % keeps_opposites)
    print('  of those, actually a way of holding a cube  %d' % len(holdable))
    print('  so a grip can undo %.1f%% of possible mistakes'
          % (100 * len(holdable) / total))
    assert keeps_opposites == 48       # 24 rotations and their 24 mirror images
    assert len(holdable) == 24
    print('  ALL PASS')


if __name__ == '__main__':
    check_a_move_is_recoverable()
    print()
    check_the_dialect_is_learned()
    print()
    check_a_wrong_table_need_not_be_a_cube()
