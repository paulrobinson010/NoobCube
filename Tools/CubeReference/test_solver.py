import random, sys, collections
import cube, solver, slots, verify_steps

FACE_MOVES = [f + s for f in 'URFDLB' for s in ['', "'", '2']]


def random_scramble(rng, n=25):
    seq, last = [], None
    while len(seq) < n:
        m = rng.choice(FACE_MOVES)
        if last and m[0] == last[0]:
            continue
        seq.append(m)
        last = m
    return seq


def run(trials=3000, seed=0):
    rng = random.Random(seed)
    lengths, stage_len = [], collections.defaultdict(list)
    fails = 0
    for i in range(trials):
        scr = random_scramble(rng)
        start = cube.apply(cube.SOLVED, scr)
        try:
            sv = solver.solve(start)
        except Exception as e:
            fails += 1
            print('FAIL', ' '.join(scr), '->', e)
            if fails > 3:
                return False
            continue
        # independent check: replay the emitted moves on the original state
        replay = cube.apply_regrip(start, sv.all_moves())
        if replay != cube.SOLVED:
            fails += 1
            print('REPLAY MISMATCH for', ' '.join(scr))
            return False
        lengths.append(len(sv.all_moves()))
        for st in sv.stages:
            stage_len[st['key']].append(len(st['moves']))
    print(f'{trials - fails}/{trials} solved')
    if lengths:
        print(f'moves: min {min(lengths)}  mean {sum(lengths)/len(lengths):.1f}  max {max(lengths)}')
        for k in ['hold','daisy','cross','corners','second','topcross','topface','topcorners','topedges']:
            v = stage_len[k]
            if v:
                print(f'  {k:11s} mean {sum(v)/len(v):5.1f}  max {max(v):3d}')
    return fails == 0


STAGE_ORDER = ['hold', 'daisy', 'cross', 'corners', 'second',
               'topcross', 'topface', 'topcorners', 'topedges']


def first_unfinished(state):
    """How far along a cube really is: stages already done come back empty."""
    for stage in solver.solve(state).stages:
        if stage['steps']:
            return stage['key']
    return None


def check_a_turn_that_undoes_finished_work(trials=40, seed=23):
    """Which turns at the start of a stage take finished work apart.

    The app lets a child turn the cube while it is still asking them whether
    they want to do the stage themselves, and most of those turns cost nothing
    — spinning the top leaves every finished layer finished. Turning a side
    does not, and quietly re-planning from there sends them back over ground
    they had won without saying why. Re-solving and seeing where the new plan
    starts is what tells the two apart.
    """
    rng = random.Random(seed)
    goes_back = collections.Counter()
    stays = collections.Counter()
    unsolvable = total = 0

    for _ in range(trials):
        start = cube.apply(cube.SOLVED, verify_steps.scramble(rng))
        plan = solver.solve(start)
        # Replay the solver's own way: rotations relabel, so the middles stay
        # where they belong. Replaying with a plain permutation instead hands
        # the solver a cube whose middles have moved, which is not a cube.
        here, stopped = start, False
        for stage in plan.stages:
            if stage['key'] == 'second':
                stopped = True
                break
            here = cube.apply_regrip(here, stage['moves'])
        if not stopped or first_unfinished(here) != 'second':
            continue

        for face in 'URFDLB':
            for suffix in ('', "'", '2'):
                total += 1
                after = cube.apply(here, [face + suffix])
                try:
                    reached = first_unfinished(after)
                except RuntimeError:
                    unsolvable += 1
                    continue
                if STAGE_ORDER.index(reached) < STAGE_ORDER.index('second'):
                    goes_back[face] += 1
                else:
                    stays[face] += 1

    print('at the start of the middle row, with the white layer finished')
    print('  %-6s %-16s %s' % ('turn', 'undoes it', 'costs nothing'))
    for face in 'URFDLB':
        print('  %-6s %-16d %d' % (face, goes_back[face], stays[face]))
    print('  cubes the solver could not solve: %d of %d' % (unsolvable, total))
    assert unsolvable == 0
    # Spinning the top never costs anything; turning any other side always does.
    assert goes_back['U'] == 0 and stays['U'] > 0
    for face in 'RFDLB':
        assert stays[face] == 0 and goes_back[face] > 0
    print('  ALL PASS')


if __name__ == '__main__':
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 3000
    ok = run(n)
    check_a_turn_that_undoes_finished_work()
    print('ALL PASS' if ok else 'FAILURES')
    sys.exit(0 if ok else 1)
