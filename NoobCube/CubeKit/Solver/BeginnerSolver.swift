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
        builder.step(lineUp: "Turn the whole cube so white is underneath and yellow is on top.",
                     outcome: "Now left and right mean the same thing to both of us.")
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
        try rounds(builder, algorithm: crossMove, goal: topCrossDone, named: "the cross move",
                   lineUp: "Turn the top until the yellow shape is pointing the right "
                         + "way: the two yellow edges at the back and on the left.",
                   outcome: "Then the cross move turns a dot into an L, an L into a "
                          + "line, and a line into the whole cross.")

        builder.begin(.yellowFace)
        try rounds(builder, algorithm: fish, goal: topFaceDone, named: "the fish",
                   lineUp: "Turn the top until the fish is looking the right way — "
                         + "yellow on the left of the side facing you.",
                   outcome: "Then the fish spins three corners at once. Do it again "
                          + "from the new shape until the whole top is yellow.")

        builder.begin(.lastCorners)
        try rounds(builder, algorithm: cornerSwap, goal: topCornersHome,
                   named: "the corner swap",
                   lineUp: "Find the two corners that want to swap and turn the top so "
                         + "they're where the swap picks them up.",
                   outcome: "The corner swap trades two corners over and leaves the "
                          + "rest alone.")

        builder.begin(.lastEdges)
        try rounds(builder, algorithm: edgeSwap, goal: solvedIgnoringTopTurn,
                   named: "the edge swap",
                   lineUp: "Turn the top so the edge that's already right is at the back.",
                   outcome: "The edge swap slides the other three round in a circle.")
        let last = finalTopTurn(builder.state)
        if !last.isEmpty {
            builder.step(lineUp: "One last spin of the top.",
                         outcome: "And that's the whole cube.")
            builder.perform(last)
        }

        guard builder.state.isSolved else {
            throw SolverError.stuck("Something went wrong working that one out. Let's scan again.")
        }

        var stages = builder.stages
        for stage in stages.indices {
            // Tidy each step on its own. Collapsing turns across a step
            // boundary would blur the very thing the steps are there to show.
            for step in stages[stage].steps.indices {
                stages[stage].steps[step].lineUp = simplify(stages[stage].steps[step].lineUp)
                stages[stage].steps[step].algorithm = simplify(stages[stage].steps[step].algorithm)
            }
            stages[stage].steps.removeAll(where: \.isEmpty)
            for number in stages[stage].steps.indices {
                stages[stage].steps[number].index = number
            }
        }
        return SolvePlan(start: state, stages: stages)
    }

    // MARK: - Bookkeeping

    /// Builds the plan as stages made of steps.
    ///
    /// A step is opened by saying which piece it is about and where that piece
    /// is going; the moves that follow are filed under it. `running()` marks
    /// where the lining up stops and the algorithm begins, which is the line
    /// the child most needs to see.
    private final class Builder {
        var state: CubeState
        var stages: [SolveStage] = []

        init(state: CubeState) {
            self.state = state
        }

        func begin(_ kind: SolveStage.Kind) {
            stages.append(SolveStage(kind: kind, steps: []))
        }

        /// Open a step. The piece's position is read now, before anything moves.
        func step(piece: Set<Face>? = nil,
                  home: Set<Face>? = nil,
                  places: Bool = true,
                  lineUp: String? = nil,
                  outcome: String? = nil,
                  algorithmName: String? = nil) {
            var step = SolveStep()
            step.lineUpText = lineUp
            step.outcome = outcome
            step.algorithmName = algorithmName
            if let piece {
                // In slot order, so it is always "the white and blue edge"
                // rather than whichever way round the set came out.
                step.piece = CubeSlots.slot(with: piece)?.faces ?? Array(piece)
                step.from = CubeSlots.slot(holding: piece, in: state)?.indices ?? []
                step.to = home.flatMap { CubeSlots.slot(with: $0)?.indices } ?? []
                step.places = places
            }
            stages[stages.count - 1].steps.append(step)
            isRunning = false
        }

        /// From here on the moves are the algorithm, not the lining up.
        func running() { isRunning = true }

        /// Say what the lining up turned out to involve. Called after it is
        /// done, because until then we do not know whether there was any.
        func explaining(lineUp: String?) {
            withLastStep { $0.lineUpText = lineUp }
        }

        /// Name the algorithm, for the stages that only know which one it is
        /// after the cube has been turned round.
        func naming(_ name: String) {
            withLastStep { $0.algorithmName = name }
        }

        private var isRunning = false

        private func withLastStep(_ change: (inout SolveStep) -> Void) {
            guard let stage = stages.indices.last,
                  let step = stages[stage].steps.indices.last else { return }
            change(&stages[stage].steps[step])
        }

        func perform(_ moves: [Move]) {
            guard !moves.isEmpty else { return }
            state = state.applying(moves)
            if stages[stages.count - 1].steps.isEmpty {
                step()
            }
            let running = isRunning
            withLastStep { step in
                if running {
                    step.algorithm.append(contentsOf: moves)
                } else {
                    step.lineUp.append(contentsOf: moves)
                }
            }
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

            let piece = Set(slot.colours(in: builder.state))

            if slot.contains(.U) {
                // Lying on its side up top: knock it down into the middle row.
                builder.step(piece: piece, places: false,
                             outcome: "This white edge is up top but lying on its side. "
                                    + "Knock it down out of the way, and we'll bring it "
                                    + "back up the right way round.")
                builder.running()
                builder.perform([Move(MoveBase(sideFace))])
            } else if slot.contains(.D) {
                if whiteFace == .D {
                    // White is pointing down, so half a turn brings it straight
                    // up, still facing outwards, and that is a petal.
                    builder.step(piece: piece, home: [.U, sideFace],
                                 lineUp: "Spin the top so the space next to the yellow "
                                       + "middle is empty.",
                                 outcome: "Then turn this side over twice and the white "
                                        + "edge comes straight up, white facing the sky.")
                } else {
                    // White is on the side, so one turn only gets it as far as
                    // the middle row; it is lifted properly next time round.
                    builder.step(piece: piece, places: false,
                                 lineUp: "This white edge is in the bottom but lying on "
                                       + "its side, so it can't go straight up.",
                                 outcome: "Turn it out into the middle row first, and then "
                                        + "we can lift it up the right way round.")
                }
                try clearPetalSlot(builder, above: sideFace)
                builder.running()
                builder.perform([Move(MoveBase(sideFace), whiteFace == .D ? .half : .clockwise)])
            } else {
                // In the middle row. Turning the face that does *not* carry the
                // white sticker leaves white pointing up when it arrives.
                guard let other = slot.sideFaces.first(where: { $0 != whiteFace }),
                      let upSlot = CubeSlots.topEdges.first(where: { $0.contains(other) }) else {
                    throw SolverError.stuck("Lost track of a white edge.")
                }
                builder.step(piece: piece, home: Set(upSlot.faces),
                             lineUp: "Spin the top so the space next to the yellow "
                                   + "middle is empty.",
                             outcome: "Then lift this white edge up by the side that "
                                    + "isn't showing white, so it arrives white-side-up.")
                try clearPetalSlot(builder, above: other)
                builder.running()
                let candidates = [Move(MoveBase(other), .clockwise),
                                  Move(MoveBase(other), .counterClockwise)]
                // It has to be *this* edge that arrives white-side-up. Asking
                // only whether the slot shows white lets another white edge
                // answer for it, and then the turn is the wrong way round.
                guard let move = candidates.first(where: { candidate in
                    let next = builder.state.applying(candidate)
                    guard let landed = CubeSlots.slot(holding: piece, in: next) else { return false }
                    return landed == upSlot && landed.sticker(on: .U, in: next) == .D
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
            let piece = Set(slot.colours(in: builder.state))
            builder.step(piece: piece, home: piece,
                         outcome: "Then turn that whole side over twice, and the white "
                                + "drops down into the cross with its side colour "
                                + "already right.")
            let spin = topTurn(from: from, to: colour)
            builder.perform(spin)
            builder.explaining(lineUp: lineUpText(
                spin,
                spin: "Spin the top until this petal's side colour is right above the "
                    + "middle that matches it.",
                grip: "",
                ready: "This petal is already above the middle that matches it."))
            builder.running()
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

            let piece = Set(target.faces)

            if here.contains(.D) {
                // Stuck in the bottom the wrong way round: lift it out first.
                builder.step(piece: piece, home: piece, places: false,
                             lineUp: "This corner is already in the bottom, but the "
                                   + "wrong way round. Turn the cube so it's at the "
                                   + "front right.",
                             outcome: "One shuffle lifts it out into the top, and then "
                                    + "we can put it in properly.")
                builder.perform(turnToFrontRight(here.sideFaces))
                builder.running()
                builder.perform(Move.parse("R U R'"))
                continue
            }
            builder.step(piece: piece, home: piece,
                         outcome: "Then spin the top to bring the corner over its gap "
                                + "and shuffle until it drops in. It only goes in the "
                                + "right way round, so keep going and it sorts itself out.",
                         algorithmName: "the shuffle")
            let grip = turnToFrontRight(target.sideFaces)
            builder.perform(grip)
            builder.explaining(lineUp: lineUpText(
                grip,
                spin: "",
                grip: "Turn the cube so this corner's gap is at the front right.",
                ready: "The gap for this corner is already at the front right."))
            builder.running()
            for round in try search(from: builder.state, algorithm: shuffle, goal: {
                frontRight.isSolved(in: $0)
            }) {
                builder.perform(round.moves)
            }
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
                let stuck = Set(unsolved[0].colours(in: builder.state))
                builder.step(piece: stuck, home: stuck, places: false,
                             lineUp: "Every edge we still need is already stuck in the "
                                   + "middle row, in the wrong place. Turn the cube so "
                                   + "one of them is at the front right.",
                             outcome: "Sending another edge in pushes this one out into "
                                    + "the top, where we can aim it properly.")
                builder.perform(turnToFrontRight(unsolved[0].faces))
                builder.running()
                builder.perform(insertRight)
                continue
            }

            let piece = Set(slot.colours(in: builder.state))
            builder.step(piece: piece, home: piece,
                         outcome: "Now send the top away from the gap it needs to go "
                                + "into. That opens the gap, drops the edge in, and puts "
                                + "everything else back where it was.")
            let spin = topTurn(from: face, to: side)
            let grip = turnToFront(side)
            builder.perform(spin)
            builder.perform(grip)
            builder.explaining(lineUp: lineUpText(
                spin + grip,
                spin: "Spin the top until this edge's front colour sits right on top of "
                    + "the middle that matches it, making a little T.",
                grip: "Turn the cube so that side is facing you.",
                ready: "This one is already lined up and facing you."))
            // Re-read after the re-grip, every face letter has just moved.
            guard let top = frontTop.sticker(on: .U, in: builder.state) else {
                throw SolverError.stuck("Lost track of a middle edge.")
            }
            builder.running()
            builder.naming(top == .R ? "send it right" : "send it left")
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

    /// One go at "turn the top, then run the algorithm".
    struct Round: Hashable, Sendable {
        var turn: [Move]
        var algorithm: [Move]
        var moves: [Move] { turn + algorithm }
    }

    /// Shortest "turn the top, then run the algorithm" sequence reaching `goal`.
    ///
    /// This is how the method is actually taught, so the child never sees a move
    /// they have not been shown. Kept as rounds rather than one long list,
    /// because a round is the unit that gets explained: line the top up, then do
    /// the one you know.
    private static func search(from start: CubeState,
                               algorithm: [Move],
                               maxRepeats: Int = 8,
                               goal: (CubeState) -> Bool) throws -> [Round] {
        if goal(start) { return [] }

        var seen: Set<CubeState> = [start]
        var queue: [(state: CubeState, path: [Round])] = [(start, [])]
        var head = 0

        while head < queue.count {
            let node = queue[head]
            head += 1
            if node.path.count >= maxRepeats { continue }

            for turn in topTurns {
                let next = node.state.applying(turn).applying(algorithm)
                let path = node.path + [Round(turn: turn, algorithm: algorithm)]
                if goal(next) { return path }
                if seen.contains(next) { continue }
                seen.insert(next)
                queue.append((next, path))
            }
        }
        throw SolverError.stuck("Couldn't work out that step. Let's scan the cube again.")
    }

    /// Describe the lining up in terms of what it actually turned out to be.
    ///
    /// A step that needed no spinning should not be told to spin, and a step
    /// that only re-grips should not be told about matching middles. Getting
    /// this wrong is worse than saying nothing: a child who follows an
    /// instruction that does not match what they are seeing stops trusting it.
    private static func lineUpText(_ moves: [Move],
                                   spin: String,
                                   grip: String,
                                   ready: String = "This one is already lined up.") -> String {
        let spun = moves.contains { $0.base == .U }
        let gripped = moves.contains(where: \.isWholeCubeTurn)
        let parts = [spun ? spin : "", gripped ? grip : ""].filter { !$0.isEmpty }
        return parts.isEmpty ? ready : parts.joined(separator: " ")
    }

    /// Run a stage as a series of rounds, one step each.
    private static func rounds(_ builder: Builder,
                               algorithm: [Move],
                               goal: (CubeState) -> Bool,
                               named: String,
                               lineUp: String,
                               outcome: String) throws {
        for round in try search(from: builder.state, algorithm: algorithm, goal: goal) {
            builder.step(lineUp: round.turn.isEmpty ? nil : lineUp,
                         outcome: outcome,
                         algorithmName: named)
            builder.perform(round.turn)
            builder.running()
            builder.perform(round.algorithm)
        }
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
