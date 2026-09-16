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
}
