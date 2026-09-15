import Foundation

enum SolverError: Error, LocalizedError {
    case notSolvable([CubeState.Problem])
    case stuck(String)

    var errorDescription: String? {
        switch self {
        case .notSolvable(let problems):
            return problems.first?.message ?? "That cube can't be solved — let's scan it again."
        case .stuck(let detail):
            return detail
        }
    }
}

/// The beginner layer-by-layer method, starting from the daisy.
///
/// The child only ever needs these, plus turning the whole cube:
///
///     the shuffle     R U R' U'
///     send it right   U R U' R' U' F' U F
///     send it left    U' L' U L U F U' F'
///     the cross move  F R U R' U' F'
///     the fish        R U R' U R U2 R'
///     the corner swap R B' R F2 R' B R F2 R2
///     the edge swap   R U' R U R U R U' R' U' R2
///
/// The last four stages search over "turn the top, then run the algorithm",
/// which is exactly how the method is taught: repeat one algorithm, lining the
/// top up in between, until the stage is done.
enum BeginnerSolver {

    // MARK: - Algorithms

    static let shuffle    = Move.parse("R U R' U'")
    static let insertRight = Move.parse("U R U' R' U' F' U F")
    static let insertLeft  = Move.parse("U' L' U L U F U' F'")
    static let crossMove  = Move.parse("F R U R' U' F'")
    static let fish       = Move.parse("R U R' U R U2 R'")
    static let cornerSwap = Move.parse("R B' R F2 R' B R F2 R2")
    static let edgeSwap   = Move.parse("R U' R U R U R U' R' U' R2")

    private static let topTurns: [[Move]] = [
        [],
        [Move(.U, .clockwise)],
        [Move(.U, .half)],
        [Move(.U, .counterClockwise)],
    ]

    /// A U turn carries a top-layer piece R -> F -> L -> B -> R; a y rotation
    /// brings the R face round to the front. Both were checked against the
    /// move engine rather than assumed.
    private static let sideStep: [Face: Face] = [.R: .F, .F: .L, .L: .B, .B: .R]

    // MARK: - Entry point

    /// Work out how to solve `state`, given which face's centre carries white.
    static func solve(_ state: CubeState, whiteFace: Face = .D) throws -> SolvePlan {
        let problems = state.validate()
        guard problems.isEmpty else { throw SolverError.notSolvable(problems) }

        let builder = Builder(state: state)

        builder.begin(.hold)
        builder.perform(rotationBringingWhiteDown(from: whiteFace))

        if bottomCrossDone(builder.state) {
            builder.begin(.daisy)
            builder.begin(.whiteCross)
        } else {
            try solveDaisy(builder)
            try solveBottomCross(builder)
        }
        try solveBottomCorners(builder)
        try solveMiddleRow(builder)

        builder.begin(.yellowCross)
        builder.perform(try search(from: builder.state, algorithm: crossMove, goal: topCrossDone))

        builder.begin(.yellowFace)
        builder.perform(try search(from: builder.state, algorithm: fish, goal: topFaceDone))

        builder.begin(.lastCorners)
        builder.perform(try search(from: builder.state, algorithm: cornerSwap, goal: topCornersHome))

        builder.begin(.lastEdges)
        builder.perform(try search(from: builder.state, algorithm: edgeSwap, goal: solvedIgnoringTopTurn))
        builder.perform(finalTopTurn(builder.state))

        guard builder.state.isSolved else {
            throw SolverError.stuck("Something went wrong working that one out. Let's scan again.")
        }

        var stages = builder.stages
        for index in stages.indices {
            stages[index].moves = simplify(stages[index].moves)
        }
        return SolvePlan(start: state, stages: stages)
    }

    // MARK: - Bookkeeping

    private final class Builder {
        var state: CubeState
        var stages: [SolveStage] = []

        init(state: CubeState) {
            self.state = state
        }

        func begin(_ kind: SolveStage.Kind) {
            stages.append(SolveStage(kind: kind, moves: []))
        }

        func perform(_ moves: [Move]) {
            guard !moves.isEmpty else { return }
            state = state.applying(moves)
            stages[stages.count - 1].moves.append(contentsOf: moves)
        }
    }

    // MARK: - Turning helpers

    private static func steps(from start: Face, to goal: Face) -> Int? {
        var face = start
        for count in 0..<4 {
            if face == goal { return count }
            guard let next = sideStep[face] else { return nil }
            face = next
        }
        return nil
    }

    /// Top turns that carry a top-layer piece from above `from` to above `to`.
    private static func topTurn(from: Face, to: Face) -> [Move] {
        guard let count = steps(from: from, to: to) else { return [] }
        return topTurns[count]
    }

    private static let yTurns: [[Move]] = [
        [],
        [Move(.y, .clockwise)],
        [Move(.y, .half)],
        [Move(.y, .counterClockwise)],
    ]

    /// Whole-cube turns that bring `face` round to the front.
    private static func turnToFront(_ face: Face) -> [Move] {
        guard let count = steps(from: face, to: .F) else { return [] }
        return yTurns[count]
    }

    /// Whole-cube turns that bring the slot spanning `pair` to the front-right.
    private static func turnToFrontRight(_ pair: [Face]) -> [Move] {
        var current = Set(pair)
        let goal: Set<Face> = [.F, .R]
        for count in 0..<4 {
            if current == goal { return yTurns[count] }
            current = Set(current.compactMap { sideStep[$0] })
        }
        return []
    }

    private static func rotationBringingWhiteDown(from face: Face) -> [Move] {
        switch face {
        case .D: return []
        case .U: return [Move(.x, .half)]
        case .F: return [Move(.x, .counterClockwise)]
        case .B: return [Move(.x, .clockwise)]
        case .R: return [Move(.z, .clockwise)]
        case .L: return [Move(.z, .counterClockwise)]
        }
    }

    // MARK: - Stage 1, the daisy

    /// Side faces whose top edge already shows white, the petals of the daisy.
    private static func petalFaces(_ state: CubeState) -> [Face] {
        CubeSlots.topEdges.compactMap { slot in
            slot.sticker(on: .U, in: state) == .D ? slot.sideFaces.first : nil
        }
    }

    /// White edges that are either a petal on top or already home on the bottom.
    private static func settledCount(_ state: CubeState) -> Int {
        petalFaces(state).count
            + CubeSlots.bottomEdges.filter { $0.isSolved(in: state) }.count
    }

    /// Turn the top until the petal slot above `face` is empty, so bringing a
    /// new white edge up cannot knock an existing petal out.
    private static func clearPetalSlot(_ builder: Builder, above face: Face) throws {
        for turn in topTurns where !petalFaces(builder.state.applying(turn)).contains(face) {
            builder.perform(turn)
            return
        }
        throw SolverError.stuck("Couldn't make room for another petal.")
    }

    private static func solveDaisy(_ builder: Builder) throws {
        builder.begin(.daisy)
        for _ in 0..<60 {
            if settledCount(builder.state) == 4 { return }

            let target = CubeSlots.edges.first { slot in
                guard slot.colours(in: builder.state).contains(.D) else { return false }
                if slot.contains(.U), slot.sticker(on: .U, in: builder.state) == .D {
                    return false                       // already a petal
                }
                if slot.contains(.D), slot.isSolved(in: builder.state) {
                    return false                       // already home, leave it alone
                }
                return true
            }
            guard let slot = target else { return }
            guard let whiteFace = slot.face(showing: .D, in: builder.state),
                  let sideFace = slot.sideFaces.first else {
                throw SolverError.stuck("Lost track of a white edge.")
            }

            if slot.contains(.U) {
                // Lying on its side up top: knock it down into the middle row.
                builder.perform([Move(MoveBase(sideFace))])
            } else if slot.contains(.D) {
                try clearPetalSlot(builder, above: sideFace)
                builder.perform([Move(MoveBase(sideFace), whiteFace == .D ? .half : .clockwise)])
            } else {
                // In the middle row. Turning the face that does *not* carry the
                // white sticker leaves white pointing up when it arrives.
                guard let other = slot.sideFaces.first(where: { $0 != whiteFace }),
                      let upSlot = CubeSlots.topEdges.first(where: { $0.contains(other) }) else {
                    throw SolverError.stuck("Lost track of a white edge.")
                }
                try clearPetalSlot(builder, above: other)
                let candidates = [Move(MoveBase(other), .clockwise),
                                  Move(MoveBase(other), .counterClockwise)]
                guard let move = candidates.first(where: {
                    upSlot.sticker(on: .U, in: builder.state.applying($0)) == .D
                }) else {
                    throw SolverError.stuck("Couldn't lift a white edge to the top.")
                }
                builder.perform([move])
            }
        }
        throw SolverError.stuck("Couldn't finish the daisy.")
    }

    // MARK: - Stage 2, the white cross

    private static func bottomCrossDone(_ state: CubeState) -> Bool {
        CubeSlots.bottomEdges.allSatisfy { $0.isSolved(in: state) }
    }

    private static func solveBottomCross(_ builder: Builder) throws {
        builder.begin(.whiteCross)
        for _ in 0..<8 {
            let petal = CubeSlots.topEdges.first { $0.sticker(on: .U, in: builder.state) == .D }
            guard let slot = petal,
                  let from = slot.sideFaces.first,
                  let colour = slot.sticker(on: from, in: builder.state) else { return }
            guard colour != .U && colour != .D else {
                throw SolverError.stuck("That white edge looks wrong.")
            }
            builder.perform(topTurn(from: from, to: colour))
            builder.perform([Move(MoveBase(colour), .half)])
        }
    }

    // MARK: - Stage 3, the white corners

    private static func solveBottomCorners(_ builder: Builder) throws {
        builder.begin(.whiteCorners)
        guard let frontRight = CubeSlots.slot(with: [.D, .F, .R]) else { return }

        for _ in 0..<20 {
            let unsolved = CubeSlots.bottomCorners.filter { !$0.isSolved(in: builder.state) }
            if unsolved.isEmpty { return }

            // Prefer a corner already waiting up top, and the one needing the
            // least re-gripping, to avoid pointless round trips.
            let target = unsolved.min { left, right in
                cost(of: left, in: builder.state) < cost(of: right, in: builder.state)
            }
            guard let target,
                  let here = CubeSlots.slot(holding: Set(target.faces), in: builder.state) else {
                throw SolverError.stuck("Lost track of a white corner.")
            }

            if here.contains(.D) {
                // Stuck in the bottom the wrong way round: lift it out first.
                builder.perform(turnToFrontRight(here.sideFaces))
                builder.perform(Move.parse("R U R'"))
                continue
            }
            builder.perform(turnToFrontRight(target.sideFaces))
            builder.perform(try search(from: builder.state, algorithm: shuffle) {
                frontRight.isSolved(in: $0)
            })
        }
        throw SolverError.stuck("Couldn't finish the white corners.")
    }

    private static func cost(of slot: CubeSlot, in state: CubeState) -> (Int, Int) {
        let here = CubeSlots.slot(holding: Set(slot.faces), in: state)
        let stuck = (here?.contains(.D) ?? false) ? 1 : 0
        return (stuck, turnToFrontRight(slot.sideFaces).count)
    }

    // MARK: - Stage 4, the middle row

    private static func solveMiddleRow(_ builder: Builder) throws {
        builder.begin(.middleRow)
        guard let frontTop = CubeSlots.slot(with: [.U, .F]) else { return }

        for _ in 0..<20 {
            let unsolved = CubeSlots.middleEdges.filter { !$0.isSolved(in: builder.state) }
            if unsolved.isEmpty { return }

            var candidate: CubeSlot?
            for slot in CubeSlots.topEdges {
                let colours = slot.colours(in: builder.state)
                if colours.contains(.U) { continue }        // belongs in the last layer
                guard let face = slot.sideFaces.first,
                      let side = slot.sticker(on: face, in: builder.state) else { continue }
                if candidate == nil { candidate = slot }
                if topTurn(from: face, to: side).isEmpty && turnToFront(side).isEmpty {
                    candidate = slot                        // already lined up, no re-grip
                    break
                }
            }

            guard let slot = candidate,
                  let face = slot.sideFaces.first,
                  let side = slot.sticker(on: face, in: builder.state) else {
                // Everything left is trapped in the middle row: pop one out.
                builder.perform(turnToFrontRight(unsolved[0].faces))
                builder.perform(insertRight)
                continue
            }

            builder.perform(topTurn(from: face, to: side))
            builder.perform(turnToFront(side))
            // Re-read after the re-grip, every face letter has just moved.
            guard let top = frontTop.sticker(on: .U, in: builder.state) else {
                throw SolverError.stuck("Lost track of a middle edge.")
            }
            builder.perform(top == .R ? insertRight : insertLeft)
        }
        throw SolverError.stuck("Couldn't finish the middle row.")
    }

    // MARK: - Stages 5 to 8, the last layer

    private static func topCrossDone(_ state: CubeState) -> Bool {
        CubeSlots.topEdges.allSatisfy { $0.sticker(on: .U, in: state) == .U }
    }

    private static func topFaceDone(_ state: CubeState) -> Bool {
        topCrossDone(state)
            && CubeSlots.topCorners.allSatisfy { $0.sticker(on: .U, in: state) == .U }
    }

    private static func topCornersHome(_ state: CubeState) -> Bool {
        CubeSlots.topCorners.allSatisfy { $0.isSolved(in: state) }
    }

    private static func solvedIgnoringTopTurn(_ state: CubeState) -> Bool {
        topTurns.contains { state.applying($0).isSolved }
    }

    private static func finalTopTurn(_ state: CubeState) -> [Move] {
        topTurns.first { state.applying($0).isSolved } ?? []
    }

    /// Shortest "turn the top, then run the algorithm" sequence reaching `goal`.
    ///
    /// This is how the method is actually taught, so the child never sees a move
    /// they have not been shown.
    private static func search(from start: CubeState,
                               algorithm: [Move],
                               maxRepeats: Int = 8,
                               goal: (CubeState) -> Bool) throws -> [Move] {
        if goal(start) { return [] }

        var seen: Set<CubeState> = [start]
        var queue: [(state: CubeState, path: [Move], depth: Int)] = [(start, [], 0)]
        var head = 0

        while head < queue.count {
            let node = queue[head]
            head += 1
            if node.depth >= maxRepeats { continue }

            for turn in topTurns {
                let next = node.state.applying(turn).applying(algorithm)
                let path = node.path + turn + algorithm
                if goal(next) { return path }
                if seen.contains(next) { continue }
                seen.insert(next)
                queue.append((next, path, node.depth + 1))
            }
        }
        throw SolverError.stuck("Couldn't work out that step. Let's scan the cube again.")
    }

    // MARK: - Tidying

    /// Collapse neighbouring turns of the same face: `U U` becomes `U2`,
    /// `U U'` disappears. Keeps the move list honest before it is shown.
    static func simplify(_ moves: [Move]) -> [Move] {
        var result: [Move] = []
        for move in moves {
            if let last = result.last, last.base == move.base {
                result.removeLast()
                let total = (last.amount.rawValue + move.amount.rawValue) % 4
                if let amount = MoveAmount(rawValue: total) {
                    result.append(Move(move.base, amount))
                }
            } else {
                result.append(move)
            }
        }
        return result
    }
}
