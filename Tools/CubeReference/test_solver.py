import random, sys, collections
import cube, solver, slots

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


if __name__ == '__main__':
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 3000
    ok = run(n)
    print('ALL PASS' if ok else 'FAILURES')
    sys.exit(0 if ok else 1)
