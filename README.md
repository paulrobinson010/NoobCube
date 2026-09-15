# NoobCube

An iOS app that teaches a child to solve a Rubik's cube, starting with the
daisy method. Built for a five year old: every instruction is spoken aloud,
nothing depends on being able to read, and the cube on screen shows each move
with an arrow pointing the way it turns.

## What it does

1. **Look at the cube.** The camera reads all six sides. A flat unfolded net
   fills in live as the child turns the cube, anchored with yellow at the top
   and white at the bottom — the way they were asked to hold it.
2. **Fold it up.** When the net is complete it folds into a 3D cube, and three
   centres light up to show how to hold it from here on.
3. **Solve it together, one stage at a time.** For each stage the child picks:
   - **Show me each move** — one move at a time, with a curved arrow around the
     turning axis and a spoken instruction. They tap "I did it!" to confirm.
   - **I'll do this bit myself** — the goal is explained and the moves listed.
     When they say they have done it, the app offers to look at the cube again.
4. **Look again, any time.** Re-scanning mid-solve is normal, not a reset.
   Stages already finished come back empty, so the child is never sent back
   over work they have done.

A GAN smart cube can replace the camera: the cube reports its own state and
every turn, so steps tick themselves off as the child turns it.

## The method

The beginner layer-by-layer method, daisy first. The child only ever needs
seven algorithms, plus turning the whole cube:

| | |
|---|---|
| the shuffle | `R U R' U'` |
| send it right | `U R U' R' U' F' U F` |
| send it left | `U' L' U L U F U' F'` |
| the cross move | `F R U R' U' F'` |
| the fish | `R U R' U R U2 R'` |
| the corner swap | `R B' R F2 R' B R F2 R2` |
| the edge swap | `R U' R U R U R U' R' U' R2` |

The last four stages are reached by searching over "turn the top, then run the
algorithm", which is exactly how the method is taught — so the child is never
shown a move they have not been taught. Solves average about 145 moves.

## Building it

Open `NoobCube.xcodeproj` and run on a device. The camera and Bluetooth both
need real hardware, so the simulator only gets you as far as the welcome
screen. Deployment target is iOS 17.

The project file is generated rather than hand-edited. After adding or removing
source files:

```
python3 Tools/generate_xcodeproj.py
```

### Branding

The artwork lives once, in `Branding/appIcon-source.png`. Everything the app
shows is cut from it:

```
python3 Tools/generate_branding.py     # needs: pip3 install Pillow
```

That produces the 1024 app icon (flattened, no alpha, as the App Store
requires), the launch screen tile, the little cube mark that sits in every
screen header, and the `NoobCube` wordmark on the welcome screen. Redraw the
icon, re-run it, and the whole app follows.

The cube mark has its edges faded to transparent rather than cropped square, so
it sits straight on the background with no visible box. The wordmark is lifted
off its dark background by treating brightness as coverage and dividing it back
out of the colour, which keeps the cyan-to-magenta gradient true.

The launch screen is a real `Info.plist` with a `UILaunchScreen` dictionary —
a generated plist cannot express it — and its background colour is the same one
the first screen uses, so the splash flows into the app.

## Layout

```
NoobCube/
  CubeKit/      cube model, move engine, validation, solver   (no UI)
  Cube3D/       SceneKit cube, turn arrows, the net-to-cube fold
  Scan/         camera, colour classification, scan flow
  Solve/        the coaching session and its screens
  SmartCube/    GAN Bluetooth support
  App/, UI/     app shell, theme, spoken instructions
Branding/
  appIcon-source.png  the master artwork every asset is cut from
Tools/
  CubeReference/      Python mirror of CubeKit, used as a test oracle
  generate_branding.py
  generate_xcodeproj.py
```

### How the cube is modelled

The 54-facelet permutation of every move is *derived from geometry*, not
transcribed from a table. A sticker is a (cubie position, outward normal) pair
and a turn rotates both, so the tables cannot be mistyped. They are checked
against algorithms whose behaviour is known independently — T-perm and Y-perm
are involutions, sune has order six, and the canonical 20-move superflip
algorithm reaches a geometrically constructed superflip.

A whole-cube rotation also **re-labels the colours**, so a solved cube still
reads as solved after a re-grip. Drawing works the other way round: the picture
of the cube is turned with the raw permutation, because what matters on screen
is which colour is physically where.

### How a scan is made reliable

Reading stickers one at a time fails under ordinary indoor light — white goes
orange. Two things fix it, both leaning on facts about cubes:

- **White balance.** A cube always has exactly nine white stickers, so the
  illuminant can be estimated from the nine palest samples without knowing
  which they are.
- **Quota assignment.** There must be exactly nine of each colour and six
  different centres, so the scan is settled as an assignment over all 54
  stickers at once rather than 54 independent guesses.

Against simulated lighting that lifts warm-indoor accuracy from 98.2% to
99.98%. What survives is caught before it reaches the solver: a scan is checked
for the three ways a cube becomes impossible — a flipped edge, a twisted
corner, a swapped pair — and any square can be tapped to correct it.

The top and bottom faces are the awkward ones to hold square to the camera, so
they are tried at all four rotations and the one that makes a solvable cube is
kept.

## Testing

`NoobCubeTests` covers the engine, the solver and the scan pipeline. Run them
in Xcode with Cmd-U.

The solver was developed against the Python reference in
`Tools/CubeReference/`, which solves thousands of random scrambles and verifies
each one by independently replaying the emitted moves onto the starting
position:

```
cd Tools/CubeReference && python3 test_solver.py 3000
```

That reference is the oracle the Swift is ported from. If you change a solver
rule, change it there first and run it.

## Known gaps

- **The GAN smart cube protocol is unverified.** GAN do not publish it; the
  constants here come from public reverse-engineering and have not been checked
  against a real cube in this build. Everything fails soft — an unsupported
  generation, a failed decrypt, or a state that could not exist all leave the
  app using the camera. Only the second-generation protocol is decoded; third
  and fourth generation cubes report themselves as unsupported rather than
  guess at bit offsets and feed the solver nonsense.
- **The Swift has not been compiled.** It was written without access to Xcode,
  so expect to fix build errors on first open. The cube logic itself is the
  part that was verified, via the Python reference.
