"""Check that every step tells the truth about the piece it claims to move.

A step says: this piece, from here, to there, by lining up and then running a
set of moves. If any of that is wrong the app teaches a child something false,
which is worse than showing them nothing. So each one is replayed and checked.
"""
import random
import cube
import slots
import solver


FACE_CENTRE = {f: cube.sticker_index(cube.NORMAL[f], cube.NORMAL[f])
               for f in ['U', 'D', 'F', 'B', 'R', 'L']}


def relabel_map(moves):
    """What each face is called after a step's whole-cube turns.

    Turning the whole cube renames the faces so that a solved cube still reads
    as solved, which means a piece cannot be followed across a step by its
    colours alone. Only x, y and z rename anything, so the map comes from
    turning a solved cube physically and reading the middles.
    """
    spins = [m for m in moves if m[0] in 'xyz']
    if not spins:
        return {f: f for f in FACE_CENTRE}
    rotated = cube.apply(cube.SOLVED, spins)
    return {rotated[index]: face for face, index in FACE_CENTRE.items()}


def placed(state, key, piece, white):
    """Whether the step's own claim about its piece came true."""
    if key == 'daisy':
        # A petal: up on the top face with its white sticker facing the sky.
        name, stickers = slots.find_edge(state, piece)
        return 'U' in name and dict(stickers)['U'] == white
    find = slots.find_corner if len(piece) == 3 else slots.find_edge
    name, _ = find(state, piece)
    return name == solver.slot_name(piece) and all(
        colour == face for face, colour in
        slots.stickers(state, (slots.CORNERS if len(piece) == 3 else slots.EDGES)[name]))


def scramble(rng, length=25):
    faces = ['U', 'D', 'F', 'B', 'R', 'L']
    moves = []
    last = None
    for _ in range(length):
        f = rng.choice([x for x in faces if x != last])
        last = f
        moves.append(f + rng.choice(['', "'", '2']))
    return moves


def check(trials=600, seed=11):
    rng = random.Random(seed)
    counts = {'steps': 0, 'with piece': 0, 'progressed': 0, 'no progress': 0}
    for trial in range(trials):
        start = cube.apply(cube.SOLVED, scramble(rng))
        sv = solver.solve(start)

        state = start
        for stage in sv.stages:
            # the steps must add up to the stage, move for move
            flat = [m for s in stage['steps'] for m in s['moves']]
            assert flat == stage['moves'], (trial, stage['key'], 'steps do not add up')

            for step in stage['steps']:
                counts['steps'] += 1
                if step['piece']:
                    counts['with piece'] += 1
                    # the piece really is where the step says it is
                    table = slots.EDGES if len(step['piece']) == 2 else slots.CORNERS
                    find = slots.find_edge if len(step['piece']) == 2 else slots.find_corner
                    at, _ = find(state, step['piece'])
                    assert [i for _, i in table[at]] == step['from'], \
                        (trial, stage['key'], 'the piece is not where the step says')
                    if step['home']:
                        assert [i for _, i in table[step['home_slot']]] == step['home'], \
                            (trial, stage['key'], 'the gap is not where the step says')

                state = cube.apply_regrip(state, step['moves'])

                if step['places']:
                    # Follow the piece across any re-grip the step contained.
                    renamed = relabel_map(step['moves'])
                    piece = {renamed[c] for c in step['piece']}
                    assert placed(state, stage['key'], piece, renamed['D']), \
                        (trial, stage['key'], 'a step claimed to place a piece and did not')
                    counts['progressed'] += 1
                elif step['piece']:
                    counts['no progress'] += 1

        assert state == cube.SOLVED, (trial, 'replaying the steps did not solve it')

    return counts


if __name__ == '__main__':
    counts = check()
    print('every step replayed, on 600 scrambled cubes:')
    print('  steps                      %d' % counts['steps'])
    print('  naming a piece             %d' % counts['with piece'])
    print('  that put a piece right     %d' % counts['progressed'])
    print('  that did not (setup steps) %d' % counts['no progress'])
