import SceneKit
import XCTest
@testable import NoobCube

/// The move engine is derived from geometry rather than from transcribed
/// permutation tables, so these tests check it against algorithms whose
/// behaviour is known independently.
final class CubeEngineTests: XCTestCase {

    func testSolvedCubeHasNineOfEachColour() {
        for face in Face.allCases {
            XCTAssertEqual(CubeState.solved.facelets.filter { $0 == face }.count, 9)
        }
        XCTAssertTrue(CubeState.solved.isSolved)
    }

    func testQuarterTurnsHaveOrderFour() {
        for base in MoveBase.allCases {
            var state = CubeState.solved
            for _ in 0..<4 {
                state = state.applying(Move(base))
            }
            XCTAssertEqual(state, .solved, "\(base) four times should do nothing")
        }
    }

    func testTurnMovesFrontToUp() {
        // An R turn carries the front face up, the top face to the back,
        // the back face down, and the bottom face to the front.
        let turned = CubeState.solved.applying("R")
        XCTAssertEqual(turned[Face.U.rawValue * 9 + 2], .F)
        XCTAssertEqual(turned[Face.B.rawValue * 9 + 0], .U)
        XCTAssertEqual(turned[Face.D.rawValue * 9 + 2], .B)
        XCTAssertEqual(turned[Face.F.rawValue * 9 + 2], .D)
    }

    func testKnownAlgorithmIdentities() {
        let cases: [(String, String, Int)] = [
            ("sexy move", "R U R' U'", 6),
            ("T-perm", "R U R' U' R' F R2 U' R' U' R U R' F'", 2),
            ("Y-perm", "F R U' R' U' R U R' F' R U R' U' R' F R F'", 2),
            ("U-perm", "R U' R U R U R U' R' U' R2", 4),
            ("sune", "R U R' U R U2 R'", 6),
        ]
        for (name, algorithm, order) in cases {
            var state = CubeState.solved
            for _ in 0..<order {
                state = state.applying(algorithm)
            }
            XCTAssertEqual(state, .solved, "\(name) should return to solved after \(order) goes")
        }
    }

    func testSuperflip() {
        // Build superflip geometrically: every edge stays put but its two
        // stickers swap. The canonical 20 move algorithm must reach it.
        var facelets = CubeState.solved.facelets
        for slot in CubeSlots.edges {
            facelets[slot.indices[0]] = CubeState.solved[slot.indices[1]]
            facelets[slot.indices[1]] = CubeState.solved[slot.indices[0]]
        }
        let superflip = CubeState(facelets: facelets)
        let reached = CubeState.solved
            .applying("U R2 F B R B2 R U2 L B2 R U' D' R2 F R' L B2 U2 F2")
        XCTAssertEqual(reached, superflip)
    }

    func testSliceAndRotationDecompositions() {
        XCTAssertEqual(CubeState.solved.applying("x R' M L"), .solved)
        XCTAssertEqual(CubeState.solved.applying("y U' E D"), .solved)
        XCTAssertEqual(CubeState.solved.applying("z F' S' B"), .solved)
    }

    func testWholeCubeRotationLeavesSolvedCubeSolved() {
        // A rotation moves stickers but re-labels the colours, exactly as a
        // person re-grips: a solved cube is still solved afterwards.
        for base in [MoveBase.x, .y, .z] {
            for amount in MoveAmount.allCases {
                XCTAssertEqual(CubeState.solved.applying(Move(base, amount)), .solved)
            }
        }
        XCTAssertNotEqual(CubeState.solved.applying("y R"), .solved)
    }

    func testNotationRoundTrip() {
        let sequence = "R U2 F' L D' B x y2 z' M E2 S"
        XCTAssertEqual(Move.notation(for: Move.parse(sequence)), sequence)
    }

    func testInverseUndoesASequence() {
        let scramble = Move.parse("R U2 F' L D' B R' U")
        let state = CubeState.solved.applying(scramble).applying(Move.invert(scramble))
        XCTAssertEqual(state, .solved)
    }

    // MARK: - Validation

    func testScrambledCubesAreValid() {
        var generator = SeededGenerator(seed: 99)
        for _ in 0..<200 {
            let state = CubeState.solved.applying(randomScramble(using: &generator))
            XCTAssertTrue(state.isValid, state.validate().map(\.message).joined())
        }
    }

    func testFlippedEdgeIsRejected() {
        guard let slot = CubeSlots.slot(with: [.U, .F]) else { return XCTFail("no UF slot") }
        var facelets = CubeState.solved.applying("R U").facelets
        facelets.swapAt(slot.indices[0], slot.indices[1])
        XCTAssertFalse(CubeState(facelets: facelets).isValid)
    }

    func testTwistedCornerIsRejected() {
        guard let slot = CubeSlots.slot(with: [.U, .F, .R]) else { return XCTFail("no UFR slot") }
        var facelets = CubeState.solved.applying("R U").facelets
        let original = slot.indices.map { facelets[$0] }
        facelets[slot.indices[0]] = original[2]
        facelets[slot.indices[1]] = original[0]
        facelets[slot.indices[2]] = original[1]
        XCTAssertFalse(CubeState(facelets: facelets).isValid)
    }

    func testSwappedPairIsRejected() {
        guard let first = CubeSlots.slot(with: [.U, .F]),
              let second = CubeSlots.slot(with: [.U, .B]) else { return XCTFail("missing slots") }
        var facelets = CubeState.solved.applying("R U").facelets
        for position in 0..<2 {
            facelets.swapAt(first.indices[position], second.indices[position])
        }
        XCTAssertFalse(CubeState(facelets: facelets).isValid)
    }

    func testMiscountedColourIsRejected() {
        var facelets = CubeState.solved.facelets
        facelets[0] = .R
        let problems = CubeState(facelets: facelets).validate()
        XCTAssertFalse(problems.isEmpty)
    }
}

// MARK: - Test helpers

/// A small reproducible generator, so a failing scramble can be looked at again.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &* 6364136223846793005 &+ 1442695040888963407
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

func randomScramble(length: Int = 25, using generator: inout SeededGenerator) -> [Move] {
    let faces: [MoveBase] = [.U, .R, .F, .D, .L, .B]
    var moves: [Move] = []
    var last: MoveBase?
    while moves.count < length {
        guard let base = faces.randomElement(using: &generator),
              let amount = MoveAmount.allCases.randomElement(using: &generator) else { continue }
        if base == last { continue }
        moves.append(Move(base, amount))
        last = base
    }
    return moves
}

/// The 3D cube has to agree with the engine about where a square has got to.
///
/// A facelet index names a *place*, and the plates travel between places. The
/// scene keeps a map from place to plate so a step can light up one square and
/// draw an arrow from it; if that map is not moved along with the cube, the
/// arrow sets off from whatever square happens to be standing in the old place.
final class CubeSceneMapTests: XCTestCase {

    private func plates() -> [Int: SCNNode] {
        var nodes: [Int: SCNNode] = [:]
        for index in 0..<54 { nodes[index] = SCNNode() }
        return nodes
    }

    private var everyMove: [Move] {
        MoveBase.allCases.flatMap { base in MoveAmount.allCases.map { Move(base, $0) } }
    }

    func testThePlateMapAgreesWithTheArrow() {
        let before = plates()
        for move in everyMove {
            let after = CubeSceneController.moved(before, by: move)
            for index in 0..<54 {
                // `follow` is what the arrow itself uses to say where a square
                // is going, so the plates must land exactly where it points.
                let landing = CubeGeometry.follow(sticker: index, through: [move])
                XCTAssertTrue(after[landing] === before[index],
                              "\(move.notation): the plate at \(index) should be at \(landing)")
            }
        }
    }

    func testThePlateMapAgreesWithTheCubeletsItRidesOn() {
        let before = plates()
        for move in everyMove {
            let after = CubeSceneController.moved(before, by: move)
            // Worked out from the move's own geometry — the cubelet turns and
            // carries its plates with it — without consulting any table.
            for (position, normal) in CubeGeometry.stickers {
                let index = CubeGeometry.faceletIndex(position: position, normal: normal)
                var carried = position
                var facing = normal
                if move.moves(cubeletAt: position) {
                    for _ in 0..<move.amount.rawValue {
                        carried = carried.rotatedClockwise(about: move.turnAxis)
                        facing = facing.rotatedClockwise(about: move.turnAxis)
                    }
                }
                let landing = CubeGeometry.faceletIndex(position: carried, normal: facing)
                XCTAssertTrue(after[landing] === before[index],
                              "\(move.notation): the plate at \(index) rides to \(landing)")
            }
        }
    }

    func testTheMapStillAgreesAfterAWholeStageOfTurns() {
        var generator = SeededGenerator(seed: 5)
        let before = plates()
        for _ in 0..<20 {
            let moves = randomScramble(length: 12, using: &generator)
            var map = before
            for move in moves { map = CubeSceneController.moved(map, by: move) }
            for index in 0..<54 {
                let landing = CubeGeometry.follow(sticker: index, through: moves)
                XCTAssertTrue(map[landing] === before[index])
            }
        }
    }
}
