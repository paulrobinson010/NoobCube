# Cube reference implementation

A Python mirror of `NoobCube/CubeKit`, used as a test oracle. The Swift code is
a direct port of this, so if you change a solver rule, change it here first and
run the tests — they check far more scrambles than is practical in XCTest.

```
python3 test_solver.py 3000
```

The test solves random scrambles and independently *replays* every emitted move
onto the original state to confirm the cube really ends solved, rather than
trusting the solver's own bookkeeping.

Nothing here ships in the app.

## Why it exists

The move engine is derived from geometry rather than from memorised permutation
tables: a sticker is a (cubie position, outward normal) pair, and a face turn
rotates both. That makes the 54-element permutations impossible to mistype, and
it is verified against known algorithm identities (T-perm and Y-perm are
involutions, sune has order 6, the 20-move superflip reaches a geometrically
constructed superflip, and so on).
