import XCTest
@testable import NoobCube

final class SolverTests: XCTestCase {

    /// Replays the plan onto the starting cube, rather than trusting the
    /// solver's own bookkeeping, and checks it really ends solved.
    private func assertSolves(_ start: CubeState,
                              whiteFace: Face = .D,
                              file: StaticString = #filePath,
                              line: UInt = #line) {
        do {
            let plan = try BeginnerSolver.solve(start, whiteFace: whiteFace)
            let finished = start.applying(plan.allMoves)
            XCTAssertTrue(finished.isSolved,
                          "plan did not solve the cube: \(Move.notation(for: plan.allMoves))",
                          file: file, line: line)
        } catch {
            XCTFail("solver failed: \(error)", file: file, line: line)
        }
    }

    func testSolvedCubeNeedsNoMoves() throws {
        let plan = try BeginnerSolver.solve(.solved)
        XCTAssertTrue(plan.isAlreadySolved)
        XCTAssertEqual(plan.moveCount, 0)
        XCTAssertNil(plan.currentStage)
    }

    func testSingleMoveScrambles() {
        for base in [MoveBase.U, .R, .F, .D, .L, .B] {
            for amount in MoveAmount.allCases {
                assertSolves(CubeState.solved.applying(Move(base, amount)))
            }
        }
    }

    func testRandomScrambles() {
        var generator = SeededGenerator(seed: 2024)
        for _ in 0..<150 {
            assertSolves(CubeState.solved.applying(randomScramble(using: &generator)))
        }
    }

    func testSolvesWithWhiteOnEveryFace() {
        var generator = SeededGenerator(seed: 7)
        for face in Face.allCases {
            for _ in 0..<15 {
                assertSolves(CubeState.solved.applying(randomScramble(using: &generator)),
                             whiteFace: face)
            }
        }
    }

    func testPlanHasEveryStageInOrder() throws {
        var generator = SeededGenerator(seed: 5)
        let start = CubeState.solved.applying(randomScramble(using: &generator))
        let plan = try BeginnerSolver.solve(start)
        XCTAssertEqual(plan.stages.map(\.kind), SolveStage.Kind.allCases)
    }

    /// The child re-scans part way through, so every stage must be a no-op once
    /// it is already done. Without this, the app would tell them to redo work.
    func testFinishedStagesAreNotRepeatedAfterRescan() throws {
        var generator = SeededGenerator(seed: 11)
        for _ in 0..<25 {
            let start = CubeState.solved.applying(randomScramble(using: &generator))
            let plan = try BeginnerSolver.solve(start)

            var state = start
            for (index, stage) in plan.stages.enumerated() {
                state = state.applying(stage.moves)
                let rescan = try BeginnerSolver.solve(state)
                for earlier in 0...index {
                    XCTAssertTrue(rescan.stages[earlier].isDone,
                                  "\(rescan.stages[earlier].kind) was repeated after it was finished")
                }
            }
            XCTAssertTrue(state.isSolved)
        }
    }

    func testOnlyTheTaughtMovesAreUsed() throws {
        var generator = SeededGenerator(seed: 3)
        for _ in 0..<30 {
            let start = CubeState.solved.applying(randomScramble(using: &generator))
            let plan = try BeginnerSolver.solve(start)
            for move in plan.allMoves {
                XCTAssertFalse(move.base.isSlice,
                               "\(move.notation) is a slice move, which the child has not been taught")
            }
        }
    }

    /// Each stage really does reach the goal it claims.
    func testEachStageReachesItsGoal() throws {
        var generator = SeededGenerator(seed: 17)
        for _ in 0..<20 {
            let start = CubeState.solved.applying(randomScramble(using: &generator))
            let plan = try BeginnerSolver.solve(start)

            let afterCross = plan.state(after: .whiteCross)
            XCTAssertTrue(CubeSlots.bottomEdges.allSatisfy { $0.isSolved(in: afterCross) },
                          "the white cross is not finished after its stage")

            let afterCorners = plan.state(after: .whiteCorners)
            XCTAssertTrue(CubeSlots.bottomCorners.allSatisfy { $0.isSolved(in: afterCorners) },
                          "the first layer is not finished after its stage")

            let afterMiddle = plan.state(after: .middleRow)
            XCTAssertTrue(CubeSlots.middleEdges.allSatisfy { $0.isSolved(in: afterMiddle) },
                          "the middle row is not finished after its stage")

            let afterYellowCross = plan.state(after: .yellowCross)
            XCTAssertTrue(CubeSlots.topEdges.allSatisfy {
                $0.sticker(on: .U, in: afterYellowCross) == .U
            }, "the yellow cross is not finished after its stage")

            let afterYellowFace = plan.state(after: .yellowFace)
            XCTAssertTrue(CubeSlots.topCorners.allSatisfy {
                $0.sticker(on: .U, in: afterYellowFace) == .U
            }, "the yellow face is not finished after its stage")

            XCTAssertTrue(plan.state(after: .lastEdges).isSolved)
        }
    }

    func testUnsolvableCubeIsRejected() {
        guard let slot = CubeSlots.slot(with: [.U, .F]) else { return XCTFail("no UF slot") }
        var facelets = CubeState.solved.applying("R U F").facelets
        facelets.swapAt(slot.indices[0], slot.indices[1])
        XCTAssertThrowsError(try BeginnerSolver.solve(CubeState(facelets: facelets)))
    }

    func testSimplifyCollapsesTurns() {
        XCTAssertEqual(BeginnerSolver.simplify(Move.parse("U U")), Move.parse("U2"))
        XCTAssertEqual(BeginnerSolver.simplify(Move.parse("U U'")), [])
        XCTAssertEqual(BeginnerSolver.simplify(Move.parse("U U2")), Move.parse("U'"))
        XCTAssertEqual(BeginnerSolver.simplify(Move.parse("R U U' R'")), Move.parse("R R'"))
    }
}
