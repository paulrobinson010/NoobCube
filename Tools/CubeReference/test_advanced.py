"""Checks for the faster methods (advanced.py), in the same spirit as
test_solver.py: solve many scrambles, replay every move independently, and
check each stage really leaves what it promises.

    python3 test_advanced.py 2000
"""
import collections
import random
import sys
import time
import cube
import advanced
import last_layer
import verify_steps
from test_solver import random_scramble

F2L = last_layer.F2L


def cross_done(state):
    return all(advanced.cross_edge_home(state, f) for f in advanced.CROSS_SIDES)


def run(trials, full, seed=0):
    rng = random.Random(seed)
    lengths, stage_len = [], collections.defaultdict(list)
    slowest = 0.0
    for _ in range(trials):
        scr = random_scramble(rng)
        start = cube.apply(cube.SOLVED, scr)
        began = time.time()
        sv = advanced.solve(start, full=full)
        slowest = max(slowest, time.time() - began)
        moves = sv.all_moves()
        assert all(m[0] in 'URFDLBxyz' for m in moves), 'not face turns'
        assert cube.apply_regrip(start, moves) == cube.SOLVED, ('replay', ' '.join(scr))

        state = start
        for stage in sv.stages:
            for step in stage['steps']:
                state = cube.apply_regrip(state, step['moves'])
                if stage['key'] == 'pairs' and step['places']:
                    # Both pieces of the pair, not just the corner the step names.
                    renamed = verify_steps.relabel_map(step['moves'])
                    piece = {renamed[c] for c in step['piece']}
                    gap = tuple(f for f in 'FBRL' if f in piece)
                    assert advanced.pair_solved(state, gap), ('pair', ' '.join(scr))
            if stage['key'] == 'cross':
                assert cross_done(state), ('cross', ' '.join(scr))
            if stage['key'] == 'pairs':
                assert all(state[i] == cube.SOLVED[i] for i in F2L), ('pairs', ' '.join(scr))
            turns = [m for m in stage['moves'] if m[0] not in 'xyz']
            stage_len[stage['key']].append(len(turns))
        lengths.append(len([m for m in moves if m[0] not in 'xyz']))
    name = 'Speedcuber' if full else 'Faster'
    print(f'{name}: {trials} solved and replayed; slowest {slowest:.2f}s')
    print(f'  turns: mean {sum(lengths)/len(lengths):.1f}  max {max(lengths)}')
    for k, v in stage_len.items():
        if k != 'hold':
            print(f'  {k:6s} mean {sum(v)/len(v):5.1f}  max {max(v):3d}')


if __name__ == '__main__':
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 1000
    for full in (False, True):
        run(n, full)
        counts = verify_steps.check(trials=max(100, n // 5), solve=lambda s: advanced.solve(s, full=full))
        print('  steps checked: %(steps)d, arrows %(arrows)d, pieces put right %(progressed)d, '
              'getting ready %(no progress)d' % counts)
    print('ALL PASS')
