import Foundation
import XCTest
@testable import NoobCube

final class SmartCubeBatteryTests: XCTestCase {

    /// A cube reported 0% while plainly working. Whatever the offsets are
    /// doing, a reading that cannot be true must never reach the screen.
    func testAnImpossibleBatteryReadingIsNotShown() {
        XCTAssertNil(SmartCubeManager.believableBattery(0),
                     "a cube that is awake and talking is not flat")
        XCTAssertNil(SmartCubeManager.believableBattery(-1))
        XCTAssertNil(SmartCubeManager.believableBattery(101))
        XCTAssertNil(SmartCubeManager.believableBattery(255),
                     "an unset byte reads as 255, which is not a percentage")
    }

    func testARealBatteryReadingIsKept() {
        for percent in [1, 42, 99, 100] {
            XCTAssertEqual(SmartCubeManager.believableBattery(percent), percent)
        }
    }
}

/// What the screen asks of the child, which is one rule rather than a predicate
/// here and an order of checks in the view.
@MainActor
final class SolvePromptTests: XCTestCase {

    /// A real plan, so the moves and the whole-cube turns in it are the ones
    /// the child would actually meet.
    private func session() throws -> SolveSession {
        var generator = SeededGenerator(seed: 4)
        let start = CubeState.solved.applying(randomScramble(using: &generator))
        let plan = try BeginnerSolver.solve(start)
        let scan = ScannedCube(colours: start.facelets.map { CubeColour.defaultColour(for: $0) })
        return SolveSession(plan: plan, scan: scan,
                            scene: CubeSceneController(), narrator: Narrator())
    }

    func testWithoutACubeEveryMoveIsConfirmedByHand() throws {
        let session = try session()
        session.cubeIsFollowing = false
        XCTAssertEqual(session.prompt, .tapWhenDone)
    }

    /// The first stage is the one that turns the whole cube to put white down,
    /// so a following cube should be asking for exactly that and nothing else.
    func testAWholeCubeTurnIsTheOneThingStillAskedFor() throws {
        let session = try session()
        session.cubeIsFollowing = true
        session.help = .moveByMove
        session.startStage()
        if session.currentMove?.isWholeCubeTurn == true {
            XCTAssertEqual(session.prompt, .turnTheWholeCube)
            XCTAssertFalse(session.pendingWholeCubeTurns.isEmpty,
                           "the turns it is waiting on should be there to be dismissed")
            XCTAssertNotNil(session.moveAfterWholeCubeTurns,
                            "and there should be a real move after them")
        } else {
            XCTAssertEqual(session.prompt, .watching)
        }
    }

    /// The run is only the turns at the front, never a turn further along that
    /// the child has not reached.
    func testOnlyTheTurnsBeingWaitedOnCount() throws {
        let session = try session()
        session.cubeIsFollowing = true
        session.help = .moveByMove
        session.startStage()
        let spins = session.pendingWholeCubeTurns
        XCTAssertTrue(spins.allSatisfy(\.isWholeCubeTurn))
        if let next = session.moveAfterWholeCubeTurns {
            XCTAssertFalse(next.isWholeCubeTurn,
                           "the move after the run must not itself be one of them")
        }
    }

    /// A turn that was not the one asked for beats everything: whatever else is
    /// true, the only thing wanted is that turn undone.
    ///
    /// The mistake is recorded before the cube on screen starts moving, which
    /// is what lets this be checked at all — nothing here spins a run loop, so
    /// an animation's completion would never arrive.
    func testPuttingItBackComesFirst() throws {
        let session = try session()
        session.cubeIsFollowing = true
        session.help = .moveByMove
        session.startStage()
        guard let expected = session.currentMove else {
            return XCTFail("the plan should have moves to make")
        }
        let wrong = Move(expected.base == .U ? .R : .U, .half)
        XCTAssertNotEqual(wrong, expected)

        session.handleSmartCubeTurn(wrong)
        XCTAssertEqual(session.wrongTurn, wrong)
        XCTAssertEqual(session.prompt, .putItBack(wrong),
                       "a mistake outranks both the watching prompt and the turn-the-cube one")
    }
}

/// A connected cube hangs entirely on knowing which way round it is being held.
///
/// Get it wrong and every turn is read as the wrong face, so a child doing
/// exactly the right thing is told they are wrong, over and over. None of it
/// can be tried without hardware, so the maths is pinned down here instead —
/// the same checks the Python reference runs.
final class CubeAlignmentTests: XCTestCase {

    /// Turning the cube in your hands: the squares move, then every centre is
    /// called by its own name again, because only the view of it has changed.
    private func regripping(_ state: CubeState, by grip: [Move]) -> CubeState {
        grip.reduce(state) { $0.applying($1).relabelled() }
    }

    func testThereAreExactlyTwentyFourWaysToHoldACube() {
        XCTAssertEqual(CubeAlignment.allGrips.count, 24)
        let shapes = Set(CubeAlignment.allGrips.map { CubeState.solved.applying($0) })
        XCTAssertEqual(shapes.count, 24, "every grip should leave the cube looking different")
        for grip in CubeAlignment.allGrips {
            XCTAssertTrue(grip.allSatisfy(\.isWholeCubeTurn))
        }
    }

    /// The scan says what the cube really looks like; the cube says what it
    /// thinks it looks like. One grip should join the two, and only one.
    func testTheGripComesBackFromAScan() {
        var generator = SeededGenerator(seed: 31)
        for _ in 0..<60 {
            let scanned = CubeState.solved.applying(randomScramble(using: &generator))
            for grip in CubeAlignment.allGrips {
                let asTheCubeSeesIt = regripping(scanned, by: grip)
                guard case .found(let alignment) =
                        CubeAlignment.matching(cube: asTheCubeSeesIt, scanned: scanned) else {
                    return XCTFail("no single grip fitted")
                }
                XCTAssertEqual(alignment.appState(of: asTheCubeSeesIt), scanned,
                               "the cube's own position should read back as the scanned one")
            }
        }
    }

    /// The whole point: a turn the cube names must come out as the turn the
    /// child was actually asked for.
    func testEveryTurnIsRenamedIntoTheAppsWords() {
        var generator = SeededGenerator(seed: 77)
        let scanned = CubeState.solved.applying(randomScramble(using: &generator))
        for grip in CubeAlignment.allGrips {
            let asTheCubeSeesIt = regripping(scanned, by: grip)
            guard case .found(let alignment) =
                    CubeAlignment.matching(cube: asTheCubeSeesIt, scanned: scanned) else {
                return XCTFail("no single grip fitted")
            }
            for base in [MoveBase.U, .R, .F, .D, .L, .B] {
                for amount in MoveAmount.allCases {
                    let asTheCubeSaysIt = Move(base, amount)
                    guard let inOurWords = alignment.appMove(for: asTheCubeSaysIt) else {
                        return XCTFail("a face turn should always have a name")
                    }
                    XCTAssertEqual(amount, inOurWords.amount, "the direction must survive")
                    // The same physical quarter turn, done in each frame.
                    XCTAssertEqual(
                        alignment.appState(of: asTheCubeSeesIt.applying(asTheCubeSaysIt)),
                        scanned.applying(inOurWords))
                }
            }
        }
    }

    /// The plan turns the whole cube; the cube in the child's hands does not
    /// know it happened. The grip has to move with them or everything after
    /// the first `y` is read as the wrong face.
    func testTurningTheWholeCubeMovesTheGripWithIt() {
        var generator = SeededGenerator(seed: 5)
        let scanned = CubeState.solved.applying(randomScramble(using: &generator))
        let spins = [Move(.x), Move(.y), Move(.z), Move(.y, .counterClockwise),
                     Move(.x, .half), Move(.z, .counterClockwise)]
        for grip in CubeAlignment.allGrips {
            let asTheCubeSeesIt = regripping(scanned, by: grip)
            guard case .found(let start) =
                    CubeAlignment.matching(cube: asTheCubeSeesIt, scanned: scanned) else {
                return XCTFail("no single grip fitted")
            }
            for spin in spins {
                let after = start.regripped(by: [spin])
                // Where the child is now holding it, the cube having stayed put.
                XCTAssertEqual(after.appState(of: asTheCubeSeesIt),
                               regripping(scanned, by: [spin]))
                for base in [MoveBase.U, .R, .F, .L] {
                    let turn = Move(base)
                    guard let named = after.appMove(for: turn) else {
                        return XCTFail("a face turn should always have a name")
                    }
                    XCTAssertEqual(after.appState(of: asTheCubeSeesIt.applying(turn)),
                                   regripping(scanned, by: [spin]).applying(named))
                }
            }
        }
    }

    /// A layer turn is never mistaken for a whole-cube turn, and a whole-cube
    /// turn never arrives from a cube in the first place.
    func testOnlyFaceTurnsCanBeRenamed() {
        for base in [MoveBase.x, .y, .z, .M, .E, .S] {
            XCTAssertNil(CubeAlignment.identity.appMove(for: Move(base)),
                         "\(base.rawValue) is not something a cube can report")
        }
        for base in [MoveBase.U, .R, .F, .D, .L, .B] {
            XCTAssertEqual(CubeAlignment.identity.appMove(for: Move(base)), Move(base))
        }
    }

    /// After a scan, the cube's own position is corrected to match what the
    /// camera saw. That is what stops the two ever disagreeing again — and a
    /// disagreement is what used to let a correct scan be thrown away and
    /// replaced with the cube's wrong idea of itself.
    func testAScanCanBePutBackIntoTheCubesOwnFrame() {
        var generator = SeededGenerator(seed: 44)
        for _ in 0..<20 {
            let scanned = CubeState.solved.applying(randomScramble(using: &generator))
            for grip in CubeAlignment.allGrips {
                let asTheCubeSeesIt = regripping(scanned, by: grip)
                guard case .found(let alignment) =
                        CubeAlignment.matching(cube: asTheCubeSeesIt, scanned: scanned) else {
                    return XCTFail("no single grip fitted")
                }
                // Turning a grip back is turning it the other way.
                XCTAssertEqual(alignment.cubeState(of: scanned), asTheCubeSeesIt,
                               "the scan, said the way the cube thinks of itself")
                XCTAssertEqual(alignment.appState(of: alignment.cubeState(of: scanned)), scanned,
                               "and back again, unchanged")
            }
        }
    }

    /// A cube whose own position has drifted is no longer a dead end.
    ///
    /// Its turns are still perfectly good, so every way of holding it stays a
    /// candidate and the child's own moves rule the wrong ones out.
    func testADriftedCubeKeepsEveryGripAsACandidate() {
        var generator = SeededGenerator(seed: 12)
        let scanned = CubeState.solved.applying(randomScramble(using: &generator))
        let drifted = scanned.applying("R")
        XCTAssertEqual(CubeAlignment.possibilities(cube: drifted, scanned: scanned).count, 24,
                       "nothing is known yet, so nothing may be ruled out")
        // And when it does agree, there is exactly one.
        XCTAssertEqual(CubeAlignment.possibilities(cube: scanned, scanned: scanned).count, 1)
    }

    /// The whole point of keeping the candidates: the move the app asked for
    /// narrows them, and they all read the turn the same way meanwhile.
    func testTheGripIsLearnedFromTheTurnsThatWereAskedFor() {
        var generator = SeededGenerator(seed: 8)
        let scanned = CubeState.solved.applying(randomScramble(using: &generator))

        for truth in CubeAlignment.allGrips {
            let held = truth.reduce(scanned) { $0.applying($1).relabelled() }
            var candidates = CubeAlignment.possibilities(cube: held.applying("R"), scanned: scanned)
            XCTAssertEqual(candidates.count, 24, "a drifted cube starts knowing nothing")

            guard case .found(let real) =
                    CubeAlignment.matching(cube: held, scanned: scanned) else {
                return XCTFail("the test's own grip should be recoverable")
            }

            var turns = 0
            for asked in [Move(.R), Move(.U, .counterClockwise), Move(.F, .half), Move(.L)] {
                // What the cube calls the move the child was asked to make.
                guard let theirs = real.appFace.first(where: { $0.value == asked.base.face })
                        .map({ Move(MoveBase(rawValue: $0.key.letter)!, asked.amount) }) else {
                    return XCTFail("every app face is some cube face")
                }
                let fitting = candidates.filter { $0.appMove(for: theirs) == asked }
                XCTAssertFalse(fitting.isEmpty, "the true grip must always survive")
                XCTAssertTrue(fitting.allSatisfy { $0.appMove(for: theirs) == asked },
                              "every survivor must read the turn the same way")
                candidates = fitting
                turns += 1
                if candidates.count == 1 { break }
            }
            XCTAssertEqual(candidates.count, 1, "the grip should come down to one")
            XCTAssertEqual(candidates[0].appFace, real.appFace)
            XCTAssertLessThanOrEqual(turns, 3, "and within three turns")
        }
    }

    /// A solved cube looks the same from every side, so no grip can be picked
    /// out. There is nothing to solve from there, so nothing is lost.
    func testASolvedCubeCannotSayWhichWayUpItIs() {
        XCTAssertEqual(CubeAlignment.matching(cube: .solved, scanned: .solved),
                       .tooSymmetricToTell)
    }

    /// When the cube's own idea of itself has drifted, no grip fits, and the
    /// app must know that rather than pick one and mislead the child.
    func testADriftedCubeIsCaughtRatherThanGuessedAt() {
        var generator = SeededGenerator(seed: 12)
        let scanned = CubeState.solved.applying(randomScramble(using: &generator))
        let drifted = scanned.applying("R")
        XCTAssertEqual(CubeAlignment.matching(cube: drifted, scanned: scanned),
                       .cubeDisagrees)
    }

    // MARK: - Finding out what the cube calls its own faces

    /// A turn is exactly determined by the positions either side of it.
    ///
    /// This is what lets the app stop believing a table about what a smart cube
    /// calls its faces and find out instead.
    func testATurnIsRecoverableFromThePositionsEitherSideOfIt() {
        var generator = SeededGenerator(seed: 73)
        var checked = 0
        for _ in 0..<40 {
            var state = CubeState.solved.applying(randomScramble(using: &generator))
            for move in Move.everyFaceTurn {
                let after = state.applying(move)
                XCTAssertEqual(Move.between(state, and: after), move,
                               "\(move.notation) was not read back")
                checked += 1
            }
            state = state.applying(randomScramble(length: 5, using: &generator))
        }
        XCTAssertEqual(checked, 40 * 18)
        // Nothing happened is not a turn.
        let still = CubeState.solved.applying(randomScramble(using: &generator))
        XCTAssertNil(Move.between(still, and: still))
    }

    /// The dialect learns a label from one turn and reads it for ever after.
    func testOneTurnTeachesWhatALabelMeans() {
        var dialect = SmartCubeDialect.unknown
        XCTAssertTrue(dialect.isEmpty)
        XCTAssertNil(dialect.move(forLabel: 3, clockwise: true))

        // This cube calls the left face "3", and its clockwise is our
        // anticlockwise.
        dialect.learn(label: 3, clockwise: true, was: Move(.L, .counterClockwise))
        XCTAssertEqual(dialect.move(forLabel: 3, clockwise: true),
                       Move(.L, .counterClockwise))
        XCTAssertEqual(dialect.move(forLabel: 3, clockwise: false), Move(.L))
        // And it still knows nothing about any other label.
        XCTAssertNil(dialect.move(forLabel: 0, clockwise: true))
    }

    /// A half turn arrives as two quarter turns, so one says nothing about
    /// which way round the cube counts. Better to stay ignorant than guess.
    func testAHalfTurnTeachesNothing() {
        var dialect = SmartCubeDialect.unknown
        dialect.learn(label: 1, clockwise: true, was: Move(.R, .half))
        XCTAssertTrue(dialect.isEmpty)
    }

    /// The whole point, end to end: a cube whose labels are in an order nobody
    /// guessed, read correctly anyway.
    ///
    /// Measured over 300 solves in `Tools/CubeReference/dialect.py`, each
    /// against a cube whose labels were shuffled and whose clockwise was a coin
    /// toss: 48,419 turns, not one read wrongly, five questions per solve.
    func testACubeWithUnexpectedLabelsIsStillReadCorrectly() {
        var generator = SeededGenerator(seed: 91)
        for _ in 0..<20 {
            // Some firmware: its six labels mean the six faces in some order.
            var faces = MoveBase.allCases.filter { !$0.isRotation }
            faces.shuffle(using: &generator)
            let reversed = Bool.random(using: &generator)
            var labelOf: [MoveBase: Int] = [:]
            for (index, face) in faces.enumerated() { labelOf[face] = index }

            var dialect = SmartCubeDialect.unknown
            var state = CubeState.solved.applying(randomScramble(using: &generator))
            var asked = 0

            for move in randomScramble(length: 40, using: &generator)
                where !move.isRotation && move.amount != .half {
                guard let label = labelOf[move.base] else { continue }
                let clockwise = (move.amount == .clockwise) != reversed
                let after = state.applying(move)

                // What the app makes of it: the dialect if it knows, and
                // otherwise the cube is asked where it is.
                var read = dialect.move(forLabel: label, clockwise: clockwise)
                if read == nil {
                    asked += 1
                    read = Move.between(state, and: after)
                }
                XCTAssertEqual(read, move, "a turn was read as the wrong move")

                if let truth = Move.between(state, and: after) {
                    dialect.learn(label: label, clockwise: clockwise, was: truth)
                }
                state = after
            }
            XCTAssertLessThanOrEqual(asked, 6, "it should ask once per face at most")
        }
    }

    // MARK: - Which way up it is, from the cube's own sensor

    private func quaternion(turning degrees: Double,
                            about axis: (Double, Double, Double))
        -> CubeOrientation.Quaternion {
        let size = (axis.0 * axis.0 + axis.1 * axis.1 + axis.2 * axis.2).squareRoot()
        let n = size > 0.000001 ? size : 1
        let half = degrees * .pi / 360
        let s = sin(half)
        return CubeOrientation.Quaternion(w: cos(half), x: axis.0 / n * s,
                                          y: axis.1 / n * s, z: axis.2 / n * s)
    }

    /// The grips are rotations, and turning one by a whole-cube move gives the
    /// rotation of the grip you land on. If this did not hold, nothing built on
    /// it would mean anything.
    func testEveryGripIsARotationThatAgreesWithItself() {
        XCTAssertEqual(CubeOrientation.everyGrip.count, 24)
        for candidate in CubeOrientation.everyGrip {
            // A rotation's inverse is its transpose, so the two must cancel.
            let back = candidate.rotation.times(candidate.rotation.inverse)
            XCTAssertEqual(back.agreement(with: .identity), 3, accuracy: 0.000001)
            // And it is the nearest thing to itself.
            XCTAssertEqual(CubeOrientation.nearestGrip(to: candidate.rotation).appFace,
                           candidate.alignment.appFace)
        }
    }

    /// GAN's axes never have to be known. The sensor's frame and the child's
    /// differ by one fixed rotation; one known grip pins it and it cancels from
    /// then on. Measured over 10,000 readings in
    /// `Tools/CubeReference/orientation.py`: exact while the cube is held
    /// within 20° of square, 99.6% at 30°.
    func testTheSensorsAxesNeverHaveToBeKnown() {
        var generator = SeededGenerator(seed: 41)
        for _ in 0..<50 {
            // Whatever frame the cube's firmware chose, and whenever its sensor
            // happened to be zeroed.
            let offset = CubeOrientation.Rotation(
                quaternion(turning: Double.random(in: 0...360, using: &generator),
                           about: (Double.random(in: -1...1, using: &generator),
                                   Double.random(in: -1...1, using: &generator),
                                   Double.random(in: -1...1, using: &generator))))

            // A moment where the grip is known some other way.
            let known = CubeOrientation.everyGrip.randomElement(using: &generator)!
            let sensorThen = offset.inverse.times(known.rotation)
            var orientation = CubeOrientation()
            orientation.calibrate(sensor: quaternionOf(sensorThen),
                                  isBeingHeldAs: known.alignment)
            XCTAssertTrue(orientation.isCalibrated)

            // Now hold it any way at all.
            for candidate in CubeOrientation.everyGrip {
                let sensorNow = offset.inverse.times(candidate.rotation)
                XCTAssertEqual(orientation.grip(sensor: quaternionOf(sensorNow))?.appFace,
                               candidate.alignment.appFace,
                               "the sensor lost track of how the cube is held")
            }
        }
    }

    /// The instruction a connected cube could never follow along with: a cube
    /// cannot feel itself being turned round in your hands, so "turn the cube
    /// around" was the one step that still needed a tap. The sensor feels it.
    func testATurnOfTheWholeCubeIsVisibleToTheSensor() {
        var generator = SeededGenerator(seed: 59)
        let offset = CubeOrientation.Rotation(
            quaternion(turning: 37, about: (0.3, 0.8, -0.5)))
        let before = CubeOrientation.everyGrip.randomElement(using: &generator)!
        var orientation = CubeOrientation()
        orientation.calibrate(sensor: quaternionOf(offset.inverse.times(before.rotation)),
                              isBeingHeldAs: before.alignment)

        for spin in ["y", "y'", "y2", "x", "x'", "x2", "z", "z'", "z2"] {
            let after = before.alignment.regripped(by: Move.parse(spin))
            let sensor = offset.inverse.times(CubeOrientation.rotation(of: after))
            XCTAssertEqual(orientation.grip(sensor: quaternionOf(sensor))?.appFace,
                           after.appFace, "\(spin) was not felt")
        }
    }

    /// A reading that is not a rotation at all must be thrown out rather than
    /// acted on — the byte offsets for this message have never been held
    /// against real hardware.
    func testNonsenseFromTheSensorIsRefused() {
        XCTAssertFalse(CubeOrientation.Quaternion(w: 0, x: 0, y: 0, z: 0).isUsable)
        XCTAssertFalse(CubeOrientation.Quaternion(w: 9, x: 9, y: 9, z: 9).isUsable)
        XCTAssertTrue(CubeOrientation.Quaternion(w: 1, x: 0, y: 0, z: 0).isUsable)

        var orientation = CubeOrientation()
        orientation.calibrate(sensor: .init(w: 0, x: 0, y: 0, z: 0),
                              isBeingHeldAs: .identity)
        XCTAssertFalse(orientation.isCalibrated, "nonsense was taken for a calibration")
        XCTAssertNil(orientation.grip(sensor: .init(w: 1, x: 0, y: 0, z: 0)),
                     "an uncalibrated sensor must not have an opinion")
    }

    /// Turning a rotation back into a quaternion, for the tests above.
    private func quaternionOf(_ r: CubeOrientation.Rotation) -> CubeOrientation.Quaternion {
        let m = r.rows
        let trace = m[0][0] + m[1][1] + m[2][2]
        if trace > 0 {
            let s = (trace + 1).squareRoot() * 2
            return .init(w: 0.25 * s, x: (m[2][1] - m[1][2]) / s,
                         y: (m[0][2] - m[2][0]) / s, z: (m[1][0] - m[0][1]) / s)
        }
        if m[0][0] > m[1][1], m[0][0] > m[2][2] {
            let s = (1 + m[0][0] - m[1][1] - m[2][2]).squareRoot() * 2
            return .init(w: (m[2][1] - m[1][2]) / s, x: 0.25 * s,
                         y: (m[0][1] + m[1][0]) / s, z: (m[0][2] + m[2][0]) / s)
        }
        if m[1][1] > m[2][2] {
            let s = (1 + m[1][1] - m[0][0] - m[2][2]).squareRoot() * 2
            return .init(w: (m[0][2] - m[2][0]) / s, x: (m[0][1] + m[1][0]) / s,
                         y: 0.25 * s, z: (m[1][2] + m[2][1]) / s)
        }
        let s = (1 + m[2][2] - m[0][0] - m[1][1]).squareRoot() * 2
        return .init(w: (m[1][0] - m[0][1]) / s, x: (m[0][2] + m[2][0]) / s,
                     y: (m[1][2] + m[2][1]) / s, z: 0.25 * s)
    }

    /// How the cube's own frame sits in a child's hands when they hold it as
    /// asked: white-on-top numbering against yellow-on-top instructions, which
    /// is half a turn apart.
    ///
    /// Top and bottom swapped, left and right swapped, front and back alone —
    /// the whole of "it turns the opposite side".
    func testTheCubesFrameIsHalfATurnFromHowTheChildHoldsIt() {
        let held = CubeAlignment.asTheChildIsAskedToHoldIt
        XCTAssertEqual(held.appFace[.U], .D)
        XCTAssertEqual(held.appFace[.D], .U)
        XCTAssertEqual(held.appFace[.R], .L)
        XCTAssertEqual(held.appFace[.L], .R)
        XCTAssertEqual(held.appFace[.F], .F)
        XCTAssertEqual(held.appFace[.B], .B)
        XCTAssertNotEqual(held.appFace, CubeAlignment.identity.appFace)
    }

    /// Every face keeps its colour across it. That is what makes it the right
    /// half turn rather than just a half turn.
    func testHoldingItAsAskedKeepsEveryColourWhereItIs() {
        let held = CubeAlignment.asTheChildIsAskedToHoldIt
        for face in Face.allCases {
            guard let landsOn = held.appFace[face] else {
                return XCTFail("\(face) went nowhere")
            }
            XCTAssertEqual(CubeColour.onTheCubesOwnFace(face),
                           CubeColour.defaultColour(for: landsOn),
                           "the cube's \(face) is not the same colour as the side it sits on")
        }
    }

    /// And it is what a turn is read with before anything has narrowed the set,
    /// which is the fallback that used to be the cube's own frame.
    func testTheFirstWayOfHoldingItIsTheWayTheyWereAsked() {
        let asked = CubeAlignment.asTheChildIsAskedToHoldIt
        let ordered = CubeAlignment.likeliestFirst(
            CubeAlignment.allGrips.map { CubeAlignment.identity.regripped(by: $0) })
        XCTAssertEqual(ordered.count, 24)
        XCTAssertEqual(ordered.first?.appFace, asked.appFace)
        XCTAssertEqual(Set(ordered.map { alignment in
            Face.allCases.map { alignment.appFace[$0]?.letter ?? "?" }.joined()
        }).count, 24, "all twenty-four must still be there, and different")

        // A turn on the cube's red face is a turn on the child's left.
        XCTAssertEqual(asked.appMove(for: Move(.R)), Move(.L))
        XCTAssertEqual(asked.appMove(for: Move(.U, .counterClockwise)),
                       Move(.D, .counterClockwise))
    }


    /// The case a child is most likely to be in: they connect a cube, the
    /// picture does not match, so they show it to the camera. A cube whose own
    /// idea of itself is wrong is exactly the case where no grip fits and all
    /// twenty-four come back — and the first of those is what a turn is read
    /// with until something narrows it.
    func testACubeThatDisagreesWithTheScanIsStillReadTheWayTheyHoldIt() {
        var generator = SeededGenerator(seed: 83)
        let asked = CubeAlignment.asTheChildIsAskedToHoldIt
        for _ in 0..<20 {
            let scanned = CubeState.solved.applying(randomScramble(using: &generator))
            // What the cube would say if its own idea of itself were right...
            let agreeing = asked.cubeState(of: scanned)
            // ...and what it says instead, having drifted.
            let drifted = agreeing.applying(Move(.R))

            XCTAssertEqual(CubeAlignment.matching(cube: drifted, scanned: scanned),
                           .cubeDisagrees)
            let candidates = CubeAlignment.possibilities(cube: drifted, scanned: scanned)
            XCTAssertEqual(candidates.count, 24)
            XCTAssertEqual(candidates.first?.appFace, asked.appFace,
                           "a turn with nothing to narrow it would be read the wrong way")
            for face in MoveBase.allCases where !face.isRotation {
                XCTAssertEqual(candidates.first?.appMove(for: Move(face)),
                               asked.appMove(for: Move(face)))
            }
        }
    }

    // MARK: - The middles are the answer

    /// A cube's middles never move relative to one another, so the face the
    /// cube calls R is its red one for ever. Where the camera found red is
    /// therefore the whole answer — whatever the cube believes about where its
    /// pieces are, and however the child is holding it.
    func testTheMiddlesGiveTheAnswerHoweverItIsHeld() {
        for grip in CubeAlignment.allGrips {
            let held = CubeAlignment.identity.regripped(by: grip)
            // What the camera would see, holding it that way round.
            var middles: [Face: CubeColour] = [:]
            for face in Face.allCases {
                guard let seenOn = held.appFace[face] else { return XCTFail("no map") }
                middles[seenOn] = CubeColour.onTheCubesOwnFace(face)
            }
            XCTAssertEqual(CubeAlignment.matching(centresSeen: middles)?.appFace,
                           held.appFace, "the middles did not give back the way it was held")
        }
    }

    /// And it works where lining up by position gives up: a cube whose own idea
    /// of where its pieces are has drifted. Which is the reason anyone reaches
    /// for the camera, so it was failing in the one case it was needed.
    func testTheMiddlesWorkWhereMatchingThePositionGivesUp() {
        var generator = SeededGenerator(seed: 29)
        let asked = CubeAlignment.asTheChildIsAskedToHoldIt
        var middles: [Face: CubeColour] = [:]
        for face in Face.allCases {
            guard let seenOn = asked.appFace[face] else { return XCTFail("no map") }
            middles[seenOn] = CubeColour.onTheCubesOwnFace(face)
        }

        for _ in 0..<20 {
            let scanned = CubeState.solved.applying(randomScramble(using: &generator))
            let drifted = asked.cubeState(of: scanned).applying(Move(.R))

            XCTAssertEqual(CubeAlignment.matching(cube: drifted, scanned: scanned),
                           .cubeDisagrees, "this test needs a cube that disagrees")
            XCTAssertEqual(CubeAlignment.matching(centresSeen: middles)?.appFace,
                           asked.appFace)
        }
    }

    /// A scan that could not name all six middles has to say so rather than
    /// answer anyway.
    func testAnIncompleteSetOfMiddlesHasNoAnswer() {
        var middles: [Face: CubeColour] = [.U: .yellow, .F: .green]
        XCTAssertNil(CubeAlignment.matching(centresSeen: middles))
        // Two sides claiming the same colour is not a cube either.
        for face in Face.allCases { middles[face] = .green }
        XCTAssertNil(CubeAlignment.matching(centresSeen: middles))
    }

    /// The numbering a cube actually uses, confirmed twice by asking one —
    /// eight turns, each named by colour so how it was held could not come
    /// into the answer:
    ///
    ///     #0 white  #1 red  #2 green  #3 yellow  #4 orange  #5 blue
    ///
    /// Seeded rather than learned, so the first turn on each face is read
    /// straight away instead of waiting a round trip for the cube to say where
    /// it is.
    func testTheDialectStartsFromTheNumberingTheseCubesUse() {
        let dialect = SmartCubeDialect.asTheseCubesNumberThem
        XCTAssertFalse(dialect.isEmpty)

        let expected: [(Int, MoveBase, CubeColour)] = [
            (0, .U, .white), (1, .R, .red), (2, .F, .green),
            (3, .D, .yellow), (4, .L, .orange), (5, .B, .blue),
        ]
        for (label, base, colour) in expected {
            XCTAssertEqual(dialect.move(forLabel: label, clockwise: true), Move(base),
                           "#\(label) should be \(base.rawValue)")
            XCTAssertEqual(dialect.move(forLabel: label, clockwise: false),
                           Move(base, .counterClockwise),
                           "#\(label) the other way should be \(base.rawValue)'")
            // And that face is the colour the check said it was.
            guard let face = Face(rawValue: label) else { return XCTFail("no face \(label)") }
            XCTAssertEqual(CubeColour.onTheCubesOwnFace(face), colour)
            XCTAssertEqual(face.letter, base.rawValue)
        }
        // Nothing beyond the six.
        XCTAssertNil(dialect.move(forLabel: 6, clockwise: true))
    }

    /// A cube that turns out to number itself differently is still learned
    /// from, so the seed is a starting point rather than an assumption.
    func testTheSeedCanStillBeCorrected() {
        var dialect = SmartCubeDialect.asTheseCubesNumberThem
        XCTAssertEqual(dialect.move(forLabel: 1, clockwise: true), Move(.R))
        dialect.learn(label: 1, clockwise: true, was: Move(.B, .counterClockwise))
        XCTAssertEqual(dialect.move(forLabel: 1, clockwise: true),
                       Move(.B, .counterClockwise))
        XCTAssertEqual(dialect.move(forLabel: 1, clockwise: false), Move(.B))
    }
}
