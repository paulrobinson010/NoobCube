import XCTest
@testable import NoobCube

/// The Faster and Speedcuber methods. The heavy checking happens in
/// `Tools/CubeReference` (every last layer, thousands of cubes); these make
/// sure the port says exactly what the reference says, and still solves.
final class PairsSolverTests: XCTestCase {

    /// The first two layers: the bottom face and the bottom two rows of each side.
    private let firstTwoLayers: [Int] = Array(Face.D.faceletIndices)
        + [Face.R, .F, .L, .B].flatMap { ($0.rawValue * 9 + 3)..<($0.rawValue * 9 + 9) }

    private func assertSolves(_ start: CubeState,
                              _ method: SolveMethod,
                              whiteFace: Face = .D,
                              file: StaticString = #filePath,
                              line: UInt = #line) {
        do {
            let plan = try method.solve(start, whiteFace: whiteFace)
            XCTAssertEqual(plan.method, method, file: file, line: line)
            XCTAssertEqual(plan.stages.map(\.kind), method.stages, file: file, line: line)
            XCTAssertTrue(start.applying(plan.allMoves).isSolved,
                          "did not solve: \(Move.notation(for: plan.allMoves))",
                          file: file, line: line)
            XCTAssertTrue(plan.allMoves.allSatisfy { $0.base.isFaceTurn || $0.base.isRotation },
                          "a slice turn crept in", file: file, line: line)
            // The first two layers are finished when the pairs are.
            let afterPairs = plan.state(after: .pairs)
            XCTAssertTrue(firstTwoLayers.allSatisfy { afterPairs[$0] == Face.of(facelet: $0) },
                          file: file, line: line)
        } catch {
            XCTFail("solver failed: \(error)", file: file, line: line)
        }
    }

    func testSolvedCubeNeedsNoMoves() throws {
        for method in [SolveMethod.faster, .speedcuber] {
            XCTAssertTrue(try method.solve(.solved).isAlreadySolved)
        }
    }

    func testRandomScrambles() {
        var generator = SeededGenerator(seed: 31)
        for _ in 0..<60 {
            let start = CubeState.solved.applying(randomScramble(using: &generator))
            assertSolves(start, .faster)
            assertSolves(start, .speedcuber)
        }
    }

    func testSolvesWithWhiteOnEveryFace() {
        var generator = SeededGenerator(seed: 8)
        for face in Face.allCases {
            let start = CubeState.solved.applying(randomScramble(using: &generator))
            assertSolves(start, .faster, whiteFace: face)
            assertSolves(start, .speedcuber, whiteFace: face)
        }
    }

    /// Move for move what `Tools/CubeReference/advanced.py` gives for the same
    /// cubes. If the two ever disagree, one of them has changed without the other.
    func testSameMovesAsTheReference() throws {
        let cases: [(scramble: String, faster: String, speedcuber: String)] = [
            ("L F R2 F' R' U2 F2 L B' U2 B F L' F D2 L F R' L2 R2",
             "F y F2 y F y R2 F R2 y F' U2 F2 R' F' R y2 R2 U' R' U R' U' R' y' U' R U R2 F R F' y2 F' U' F F U R U' R' F' R2 D R' U2 R D' R' U2 R' U' R2 U R U R' U' R' U' R' U R'",
             "F y F2 y F y R2 F R2 y F' U2 F2 R' F' R y2 R2 U' R' U R' U' R' y' U' R U R2 F R F' y2 F' U' F U2 F' U' L' U L F U' F' U' L' U L F U' R U R' U' D R2 U' R U' R' U R' U R2 D'"),
            ("D' U2 B' U2 B D' L U' F2 B2 U L' F D2 B2 U2 L2 B' F L2",
             "U' F2 y U' R' F y R U R' F2 y2 R F R2 U2 F' R' y' R U F U' F' U' R' y2 U' F' R' U R U' F y R U' R' U2 F' U' F F R U R' U' F' U2 F U R U' R' F' R2 D R' U2 R D' R' U2 R' F R U' R' U' R U R' F' R U R' U' R' F R F' U R2 U R U R' U' R' U' R' U R' U2",
             "U' F2 y U' R' F y R U R' F2 y2 R F R2 U2 F' R' y' R U F U' F' U' R' y2 U' F' R' U R U' F y R U' R' U2 F' U' F U2 F' U' L' U L F U' F R U R' U' F' U' R' U' R U D' R2 U R' U R U' R U' R2 D U"),
            ("U' D2 R' F R2 L2 R2 B' R2 U' R U R2 B L' U2 L' U2 R' D",
             "y2 R2 F y U2 F2 y U F2 y U' F2 y U' R U R' y2 R F R F' R' y' U2 F' U2 F2 R' F' R y2 F' U2 F U2 F U R U' R' F' U2 R2 D R' U2 R D' R' U2 R' F R U' R' U' R U R' F' R U R' U' R' F R F' U",
             "y2 R2 F y U2 F2 y U F2 y U' F2 y U' R U R' y2 R F R F' R' y' U2 F' U2 F2 R' F' R y2 F' U2 F F R U R' U' F' U F R U R' U' F' U R' U' F' R U R' U' R' F R2 U' R' U' R U R' U R U"),
        ]
        for example in cases {
            let start = CubeState.solved.applying(example.scramble)
            XCTAssertEqual(Move.notation(for: try SolveMethod.faster.solve(start).allMoves),
                           example.faster, example.scramble)
            XCTAssertEqual(Move.notation(for: try SolveMethod.speedcuber.solve(start).allMoves),
                           example.speedcuber, example.scramble)
        }
    }

    // MARK: - The algorithm tables

    func testEveryAlgorithmKeepsTheFirstTwoLayersAndIsFaceTurns() {
        let tables = [LastLayer.edges, LastLayer.yellowFace, LastLayer.cornerSwaps,
                      LastLayer.edgeCycles, LastLayer.oll, LastLayer.pll]
        for algorithm in tables.flatMap({ $0 }) {
            XCTAssertTrue(algorithm.moves.allSatisfy(\.base.isFaceTurn), algorithm.name)
            let after = CubeState.solved.applying(algorithm.moves)
            XCTAssertTrue(firstTwoLayers.allSatisfy { after[$0] == Face.of(facelet: $0) },
                          "\(algorithm.name) breaks the first two layers")
        }
        XCTAssertEqual(LastLayer.oll.count, 57)
        XCTAssertEqual(LastLayer.pll.count, 21)
    }

    func testEveryOLLSolvesItsOwnCase() {
        for algorithm in LastLayer.oll {
            let before = CubeState.solved.applying(Move.invert(algorithm.moves))
            XCTAssertFalse(LastLayer.isOriented(before), algorithm.name)
            XCTAssertTrue(LastLayer.isOriented(before.applying(algorithm.moves)), algorithm.name)
            XCTAssertEqual(try LastLayer.orientInOneLook(before).count, 1)
        }
    }

    func testEveryPLLSolvesItsOwnCase() throws {
        for algorithm in LastLayer.pll {
            let before = CubeState.solved.applying(Move.invert(algorithm.moves))
            XCTAssertTrue(LastLayer.isOriented(before), algorithm.name)
            XCTAssertFalse(before.isSolved, algorithm.name)
            let looks = try LastLayer.permuteInOneLook(before)
            XCTAssertEqual(looks.count, 1)
            // And the two-look way gets there too.
            var state = before
            for look in try LastLayer.permuteInTwoLooks(before) {
                state = state.applying(look.turn + look.moves)
            }
            XCTAssertTrue(LastLayer.isSolvedIgnoringTopTurn(state), algorithm.name)
        }
    }

    func testTheDotTakesTwoGoesToMakeTheCross() throws {
        // The line and the hook, one after the other, from a solved top.
        let dot = CubeState.solved.applying(Move.invert(Move.parse("F R U R' U' F' U2 F U R U' R' F'")))
        XCTAssertFalse([1, 3, 5, 7].contains { dot[$0] == .U })
        let looks = try LastLayer.orientInTwoLooks(dot)
        XCTAssertEqual(looks.prefix(2).map(\.name), ["the line", "the hook"])
    }

    // MARK: - Numbering

    func testEachMethodNumbersItsOwnStages() {
        XCTAssertEqual(SolveMethod.beginner.numbered.count, 8)
        XCTAssertEqual(SolveMethod.faster.numbered.count, 6)
        XCTAssertEqual(SolveMethod.speedcuber.numbered.count, 4)
        XCTAssertEqual(SolveStage.Kind.daisy.number, 1)
        XCTAssertEqual(SolveStage.Kind.lastEdges.number, 8)
        XCTAssertEqual(SolveStage.Kind.cross.number, 1)
        XCTAssertEqual(SolveStage.Kind.pairs.number, 2)
        XCTAssertEqual(SolveStage.Kind.topEdges.number, 6)
        XCTAssertEqual(SolveStage.Kind.oll.number, 3)
        XCTAssertEqual(SolveStage.Kind.pll.number, 4)
        XCTAssertNil(SolveStage.Kind.hold.number)
    }
}
