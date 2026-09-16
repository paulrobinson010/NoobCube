#!/usr/bin/env python3
"""Replay a scanned cube through the reference solver.

The app prints one line when a solve begins:

    NoobCube cube: UUFRUBLD…

Paste the 54 letters in here and every stage and step is rebuilt and checked,
so a solve that went wrong on a phone can be looked at on a desk.

    python3 Tools/replay.py UUFRUBLD…
"""
import sys, pathlib

sys.path.insert(0, str(pathlib.Path(__file__).parent / "CubeReference"))
import cube, solver, slots, verify_steps


def replay(letters):
    letters = "".join(letters.split()).replace("NoobCube cube:", "").strip()
    if len(letters) != 54:
        raise SystemExit(f"expected 54 letters, got {len(letters)}")
    if set(letters) != set("URFDLB"):
        raise SystemExit(f"expected only U R F D L B, got {sorted(set(letters))}")
    for face in "URFDLB":
        if letters.count(face) != 9:
            raise SystemExit(f"{letters.count(face)} {face} stickers, and there should be 9")

    state = letters
    sv = solver.solve(state)
    print(f"{sum(len(s['moves']) for s in sv.stages)} moves in "
          f"{len(sv.stages)} stages\n")

    for stage in sv.stages:
        print(f"{stage['key']:<12} {stage['title']}  ({len(stage['moves'])} moves, "
              f"{len(stage['steps'])} steps)")
        for index, step in enumerate(stage['steps']):
            piece = "".join(sorted(step['piece'])) if step['piece'] else "—"
            print(f"    {index:>2}  {piece:<4} {' '.join(step['moves']) or '(nothing)':<28}"
                  f" marker {step['marker']} → {step['target']}")

    # The same checks the test suite runs, on this one cube.
    state = letters
    for stage in sv.stages:
        for step in stage['steps']:
            assert solver.follow(step['marker'], step['moves']) == step['target'], \
                f"the arrow in {stage['key']} step points at the wrong place"
            state = cube.apply_regrip(state, step['moves'])
    assert state == cube.SOLVED, "replaying the steps did not solve it"
    print("\nevery step checked, and it solves.")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    replay(" ".join(sys.argv[1:]))
