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
///     righty          R U R' U'
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

    static let righty      = Move.parse("R U R' U'")
    static let insertRight = Move.parse("U R U' R' U' F' U F")
    static let insertLeft  = Move.parse("U' L' U L U F U' F'")
    static let crossMove  = Move.parse("F U R U' R' F'")
    static let fish       = Move.parse("R U R' U R U2 R'")
    static let cornerSwap = Move.parse("R B' R F2 R' B R F2 R2")
    static let edgeSwap   = Move.parse("F2 U R' L F2 L' R U F2")

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
        builder.step(grip: "Turn the whole cube so white is underneath and yellow is on top.",
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
        try rounds(builder, algorithm: crossMove, goal: topCrossDone,
                   ready: crossReady, named: "the cross move",
                   spin:   "Look at the yellow on top. You will see a dot, or a bent "
                         + "L, or a line. Turn the top until a line lies left to "
                         + "right, or an L points at the back and the left. A dot "
                         + "can stay where it is. The move only works from there, "
                         + "which is the whole reason we turn the top first.",
                   outcome: "The cross move turns a dot into an L, an L into a line, "
                          + "and a line into the cross. Same six moves every time — "
                          + "it is the shape you start from that changes.")

        builder.begin(.yellowFace)
        try rounds(builder, algorithm: fish, goal: topFaceDone,
                   ready: fishReady, named: "the fish",
                   spin:   "The fish is one corner with yellow on top and two yellow "
                         + "stickers beside it, all pointing the same way. Count the "
                         + "corners with yellow on top: if one has, turn the top until "
                         + "it is the front left one. If none have, or two have, turn "
                         + "the top until the front left corner has its yellow looking "
                         + "left. That is where the fish starts.",
                   outcome: "The fish spins three corners and leaves the fourth alone, "
                          + "so more yellow comes up each go. Look for the fish again "
                          + "and do it again until the whole top is yellow.")

        builder.begin(.lastCorners)
        try rounds(builder, algorithm: cornerSwap, goal: topCornersHome,
                   named: "the corner swap",
                   spin:   "Find the two corners that want to swap and turn the top so "
                         + "they're where the swap picks them up.",
                   outcome: "The corner swap trades two corners over and leaves the "
                          + "rest alone.")

        builder.begin(.lastEdges)
        try rounds(builder, algorithm: edgeSwap, goal: solvedIgnoringTopTurn,
                   ready: edgesReady,
                   named: "the edge swap",
                   spin:   "Turn the top so the edge that is already home is at the "
                         + "back. If none of them is home yet, any turn will do — "
                         + "the first go will put one right.",
                   outcome: "The edge swap leaves that one alone and slides the "
                          + "other three round in a circle.")
        let last = finalTopTurn(builder.state)
        if !last.isEmpty {
            builder.step(spin: "One last spin of the top.",
                         outcome: "And that's the whole cube.")
            builder.perform(last)
        }

        guard builder.state.isSolved else {
            throw SolverError.stuck("Something went wrong working that one out. Let's scan again.")
        }

        return SolvePlan(start: state, stages: assemble(builder, from: state))
    }

    // MARK: - Bookkeeping

    /// One piece's worth of work, as written down by the stage solvers.
    ///
    /// It is split into the steps the child actually sees at the end, because
    /// only then is it known what the lining up turned out to consist of.
    private struct Draft {
        var piece: Set<Face>?
        var home: Set<Face>?
        /// The words for each kind of positioning. Each one is only ever shown
        /// when its own moves happened, so nothing can claim a turn that was
        /// never made.
        var spin: String?
        var grip: String?
        var turn: String?
        var outcome: String?
        var algorithmName: String?
        var places = true
        var liningUp: [Move] = []
        var algorithm: [Move] = []
    }

    /// Builds the plan: stages, each a list of drafts.
    private final class Builder {
        var state: CubeState
        private(set) var kinds: [SolveStage.Kind] = []
        private(set) var drafts: [[Draft]] = []

        init(state: CubeState) {
            self.state = state
        }

        func begin(_ kind: SolveStage.Kind) {
            kinds.append(kind)
            drafts.append([])
        }

        func step(piece: Set<Face>? = nil,
                  home: Set<Face>? = nil,
                  places: Bool = true,
                  spin: String? = nil,
                  grip: String? = nil,
                  turn: String? = nil,
                  outcome: String? = nil,
                  algorithmName: String? = nil) {
            var draft = Draft()
            draft.piece = piece
            draft.home = home
            draft.places = piece == nil ? false : places
            draft.spin = spin
            draft.grip = grip
            draft.turn = turn
            draft.outcome = outcome
            draft.algorithmName = algorithmName
            drafts[drafts.count - 1].append(draft)
            isRunning = false
        }

        /// From here on the moves are the algorithm, not the lining up.
        func running() { isRunning = true }

        /// Name the algorithm, for the stages that only know which one it is
        /// after the cube has been turned round.
        func naming(_ name: String) {
            withLastDraft { $0.algorithmName = name }
        }

        private var isRunning = false

        private func withLastDraft(_ change: (inout Draft) -> Void) {
            guard let stage = drafts.indices.last,
                  let draft = drafts[stage].indices.last else { return }
            change(&drafts[stage][draft])
        }

        func perform(_ moves: [Move]) {
            guard !moves.isEmpty else { return }
            state = state.applying(moves)
            if drafts[drafts.count - 1].isEmpty { step() }
            let running = isRunning
            withLastDraft { draft in
                if running {
                    draft.algorithm.append(contentsOf: moves)
                } else {
                    draft.liningUp.append(contentsOf: moves)
                }
            }
        }
    }

    // MARK: - Turning a draft into steps

    /// What each face is called after these moves.
    ///
    /// Turning the whole cube renames the faces so a solved cube still reads as
    /// solved, so a piece cannot be followed across one by its colours alone.
    private static func renaming(after moves: [Move]) -> [Face: Face] {
        var map: [Face: Face] = [:]
        for face in Face.allCases {
            let landing = CubeGeometry.follow(sticker: face.centreIndex, through: moves)
            map[face] = Face.allCases.first { $0.centreIndex == landing } ?? face
        }
        return map
    }

    /// The square on a piece worth watching: its white one if it has one.
    private static func keySticker(of piece: Set<Face>, in state: CubeState) -> Int? {
        guard let slot = CubeSlots.slot(holding: piece, in: state) else { return nil }
        for wanted in [Face.D, .U] {
            if let position = slot.indices.firstIndex(where: { state[$0] == wanted }) {
                return slot.indices[position]
            }
        }
        return slot.indices.first
    }

    /// One square to watch, and where these moves put it.
    ///
    /// Always a square that really moves. A child told to watch something that
    /// stays still while the cube changes around it learns nothing, which is
    /// what made the old lining-up instructions so baffling.
    private static func marks(for piece: Set<Face>?,
                              home: [Int],
                              moves: [Move],
                              in state: CubeState) -> (marker: Int, target: Int)? {
        func travelled(_ index: Int) -> (Int, Int)? {
            let landing = CubeGeometry.follow(sticker: index, through: moves)
            return landing == index ? nil : (index, landing)
        }

        if let piece, let key = keySticker(of: piece, in: state), let found = travelled(key) {
            return found
        }

        if moves.contains(where: \.isWholeCubeTurn) {
            // The cube itself is turning: watch the middle that ends up facing you.
            for face in Face.allCases where face != .F {
                if CubeGeometry.follow(sticker: face.centreIndex, through: moves)
                    == Face.F.centreIndex {
                    return (face.centreIndex, Face.F.centreIndex)
                }
            }
        }

        // Making room: the square to watch is the one that is in the way.
        if let first = home.first, let found = travelled(first) { return found }

        // A last-layer algorithm moves several pieces at once. Watch a square
        // it puts right, looking at the top face first because that is where
        // the child is looking.
        let after = state.applying(moves)
        let order = Array(Face.U.faceletIndices) + (0..<54).filter { !Face.U.faceletIndices.contains($0) }
        for index in order {
            let landing = CubeGeometry.follow(sticker: index, through: moves)
            guard landing != index else { continue }
            if state[index] != Face.of(facelet: index),
               after[landing] == Face.of(facelet: landing) {
                return (index, landing)
            }
        }

        // Nothing is put right by this one — it is setting the shape up for the
        // next go. Watch a square that at least travels somewhere.
        for index in order {
            if let found = travelled(index) { return found }
        }
        return nil
    }

    /// Break one draft into the things it actually asks the child to do.
    ///
    /// Spinning the top, turning the whole cube and freeing a piece are
    /// different actions with different things to look at, so each gets its own
    /// step. The words for each only exist when its moves do.
    private static func runs(of draft: Draft) -> [(purpose: SolveStep.Purpose,
                                                   moves: [Move],
                                                   text: String?)] {
        enum Kind { case spin, grip, turn }
        func kind(of move: Move) -> Kind {
            if move.isWholeCubeTurn { return .grip }
            return move.base == .U ? .spin : .turn
        }
        func words(_ kind: Kind) -> String? {
            switch kind {
            case .spin: return draft.spin
            case .grip: return draft.grip
            case .turn: return draft.turn
            }
        }

        var out: [(SolveStep.Purpose, [Move], String?)] = []
        var run: [Move] = []
        var current: Kind?
        for move in draft.liningUp {
            let this = kind(of: move)
            if let current, this != current {
                out.append((.positioning, run, words(current)))
                run = []
            }
            current = this
            run.append(move)
        }
        if let current, !run.isEmpty {
            out.append((.positioning, run, words(current)))
        }
        if !draft.algorithm.isEmpty {
            out.append((.move, draft.algorithm, draft.outcome))
        }
        return out
    }

    /// Turn the drafts into the steps the child is shown.
    ///
    /// Everything is worked out by replaying the solve from the beginning,
    /// because a square's position, the name of a face, and what is sitting in
    /// the way are all facts about a particular moment.
    private static func assemble(_ builder: Builder, from start: CubeState) -> [SolveStage] {
        var stages: [SolveStage] = []
        var state = start

        for (stageIndex, kind) in builder.kinds.enumerated() {
            var steps: [SolveStep] = []

            for var draft in builder.drafts[stageIndex] {
                // Tidy each part on its own: collapsing turns across the line
                // between lining up and the move would blur the very thing the
                // steps are there to show.
                draft.liningUp = simplify(draft.liningUp)
                draft.algorithm = simplify(draft.algorithm)

                // A draft's piece is named in the labels of the moment it was
                // written down, so renaming runs from there rather than from
                // the start of the solve.
                var naming: [Face: Face] = [:]
                for face in Face.allCases { naming[face] = face }

                for run in runs(of: draft) where !run.moves.isEmpty {
                    var step = SolveStep()
                    step.purpose = run.purpose
                    step.moves = run.moves
                    step.text = run.text
                    step.algorithmName = run.purpose == .move ? draft.algorithmName : nil
                    step.places = draft.places && run.purpose == .move

                    var piece: Set<Face>?
                    if let authored = draft.piece {
                        let now = Set(authored.compactMap { naming[$0] })
                        piece = now
                        step.piece = CubeSlots.slot(with: now)?.faces ?? Array(now)
                        step.from = CubeSlots.slot(holding: now, in: state)?.indices ?? []
                        // The gap it is going into: its own slot, unless the
                        // draft named another one — the daisy aims at a petal.
                        let home = draft.home == draft.piece ? now : (draft.home ?? now)
                        step.to = CubeSlots.slot(with: home)?.indices ?? []
                    }

                    if let found = marks(for: piece, home: step.to,
                                         moves: run.moves, in: state) {
                        step.marker = found.marker
                        step.target = found.target
                    }

                    step.index = steps.count
                    steps.append(step)

                    state = state.applying(run.moves)
                    let renamed = renaming(after: run.moves)
                    naming = naming.mapValues { renamed[$0] ?? $0 }
                }
            }
            stages.append(SolveStage(kind: kind, steps: steps))
        }
        return stages
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

    /// Turns of the top that empty the petal slot above `face`, so that turning
    /// that face cannot knock an existing petal out. Turning the top only moves
    /// petals around the top, so it never costs one.
    private static func roomAbove(_ face: Face, in state: CubeState) throws -> [Move] {
        for turn in topTurns where !petalFaces(state.applying(turn)).contains(face) {
            return turn
        }
        throw SolverError.stuck("Couldn't make room for another petal.")
    }

    /// One white edge's whole journey into the daisy.
    private struct PetalPlan {
        var moves: [Move]
        /// The petal slot it ends up in, for pointing at.
        var petal: Set<Face>
        /// How many moves at the front are lining up rather than lifting.
        var liningUp: Int
    }

    /// Everything it takes to bring one white edge up into the daisy.
    ///
    /// One edge, one plan, however awkwardly it happens to be sitting. This
    /// used to take two goes for an edge lying on its side — one to knock it
    /// out of the way and another to lift it — which meant the app named a
    /// piece, moved something else, and then named the same piece again. No
    /// child can follow that, and it is not how anybody teaches the daisy.
    private static func petalPlan(for piece: Set<Face>,
                                  in start: CubeState) throws -> PetalPlan {
        var moves: [Move] = []
        var state = start

        func look() throws -> (slot: CubeSlot, white: Face) {
            guard let slot = CubeSlots.slot(holding: piece, in: state),
                  let white = slot.face(showing: .D, in: state) else {
                throw SolverError.stuck("Lost track of a white edge.")
            }
            return (slot, white)
        }

        var (slot, white) = try look()

        if slot.contains(.U), slot.sticker(on: .U, in: state) != .D {
            // Lying on its side up top. Knock it down into the middle row,
            // where it can be lifted back up the right way round. Nothing else
            // is up there to disturb: this is the slot it is sitting in.
            guard let side = slot.sideFaces.first else {
                throw SolverError.stuck("Lost track of a white edge.")
            }
            let turn = [Move(MoveBase(side))]
            moves += turn
            state = state.applying(turn)
            (slot, white) = try look()
        }

        if slot.contains(.D), white != .D {
            // In the bottom but lying on its side, so it cannot come straight
            // up. One turn puts it in the middle row, where it can be aimed.
            guard let side = slot.sideFaces.first else {
                throw SolverError.stuck("Lost track of a white edge.")
            }
            let turn = try roomAbove(side, in: state) + [Move(MoveBase(side))]
            moves += turn
            state = state.applying(turn)
            (slot, white) = try look()
        }

        // Where it is going, and the turn that takes it there.
        let face: Face
        var lift: [Move]?
        if slot.contains(.D) {
            guard let side = slot.sideFaces.first else {
                throw SolverError.stuck("Lost track of a white edge.")
            }
            face = side
            lift = [Move(MoveBase(side), .half)]
        } else {
            guard let other = slot.sideFaces.first(where: { $0 != white }) else {
                throw SolverError.stuck("Lost track of a white edge.")
            }
            face = other
            lift = nil
        }
        guard let petalSlot = CubeSlots.topEdges.first(where: { $0.contains(face) }) else {
            throw SolverError.stuck("Lost track of a white edge.")
        }

        let clear = try roomAbove(face, in: state)
        moves += clear
        state = state.applying(clear)

        if lift == nil {
            // It has to be *this* edge that arrives white-side-up. Asking only
            // whether the slot shows white lets another white edge answer for
            // it, and then the turn is the wrong way round.
            let candidates = [Move(MoveBase(face), .clockwise),
                              Move(MoveBase(face), .counterClockwise)]
            lift = candidates.first { candidate in
                let next = state.applying(candidate)
                guard let landed = CubeSlots.slot(holding: piece, in: next) else { return false }
                return landed == petalSlot && landed.sticker(on: .U, in: next) == .D
            }.map { [$0] }
        }
        guard let lift else {
            throw SolverError.stuck("Couldn't lift a white edge into the daisy.")
        }

        return PetalPlan(moves: moves + lift,
                         petal: Set(petalSlot.faces),
                         liningUp: moves.count)
    }

    private static func solveDaisy(_ builder: Builder) throws {
        builder.begin(.daisy)
        for _ in 0..<8 {
            if settledCount(builder.state) == 4 { return }

            // Every white edge still to do, with what each would cost. The
            // cheapest is taken, which is what anybody does by eye: an edge
            // already sitting beside a middle needs one turn and nothing else.
            var cheapest: (piece: Set<Face>, plan: PetalPlan)?
            for slot in CubeSlots.edges {
                guard slot.colours(in: builder.state).contains(.D) else { continue }
                if slot.contains(.U), slot.sticker(on: .U, in: builder.state) == .D {
                    continue                           // already a petal
                }
                if slot.contains(.D), slot.isSolved(in: builder.state) {
                    continue                           // already home, leave it alone
                }
                let piece = Set(slot.colours(in: builder.state))
                let plan = try petalPlan(for: piece, in: builder.state)
                if cheapest == nil || plan.moves.count < cheapest!.plan.moves.count {
                    cheapest = (piece, plan)
                }
            }
            guard let (piece, plan) = cheapest else { return }

            builder.step(piece: piece, home: plan.petal,
                         spin: "Spin the top to move this out of the space we need.",
                         turn: "Turn this side to bring the white square out where we "
                             + "can lift it.",
                         outcome: plan.moves.count == 1
                             ? "This one's the easiest — one turn lifts it straight "
                             + "into the daisy."
                             : "Now one turn lifts it into the daisy, white facing the sky.")
            builder.perform(Array(plan.moves.prefix(plan.liningUp)))
            builder.running()
            builder.perform(Array(plan.moves.dropFirst(plan.liningUp)))
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
                         spin: "Spin the top until this colour is above the middle "
                             + "that matches it.",
                         grip: "Turn the cube so that side faces you, and check: the "
                             + "colour on the petal and the middle underneath have to "
                             + "match. If they don't, the cube can't come out right.",
                         outcome: "Now turn this whole side over twice. The white "
                                + "drops to the bottom and the colour stays matched.")
            builder.perform(topTurn(from: from, to: colour))
            // Bring that side to the front so the child can see the match for
            // themselves. Lining the colours up is the whole point of this
            // stage: a cross with the sides wrong looks finished and is not.
            builder.perform(turnToFront(colour))
            builder.running()
            builder.perform([Move(.F, .half)])
        }
    }

    // MARK: - Stage 3, the white corners

    /// What it takes to put one corner in, the way it is taught.
    private struct CornerPlan {
        var grip: [Move]
        var spin: [Move]
        var moves: [Move]
        /// False for a corner that has to come out of the bottom first.
        var places: Bool
        var length: Int { grip.count + spin.count + moves.count }
    }

    /// Turn the cube so the gap is at the front right, spin the top until the
    /// corner sits over it, then righty until it drops in.
    ///
    /// That is the whole method — no searching and nothing to work out, and a
    /// child can check every part of it by looking at the middles. It costs
    /// more turns than hunting for the shortest way in, which is the trade:
    /// a corner takes one, three or five rightys and never more.
    private static func cornerPlan(for slot: CubeSlot,
                                   in state: CubeState) throws -> CornerPlan {
        guard let here = CubeSlots.slot(holding: Set(slot.faces), in: state),
              let frontRight = CubeSlots.slot(with: [.D, .F, .R]),
              let aboveIt = CubeSlots.slot(with: [.U, .F, .R]) else {
            throw SolverError.stuck("Lost track of a white corner.")
        }
        if here.contains(.D) {
            // No corner is waiting up top, so one has to be lifted out. A whole
            // righty does that just as well as the three moves it starts with —
            // checked on 767 stuck corners — and it keeps the child's whole
            // vocabulary for this stage down to one thing.
            return CornerPlan(grip: turnToFrontRight(here.sideFaces), spin: [],
                              moves: righty, places: false)
        }

        let grip = turnToFrontRight(slot.sideFaces)
        let gripped = state.applying(grip)
        // The gap is the front-right one now, so the corner that belongs in it
        // is the one carrying those three colours.
        let piece = Set(frontRight.faces)
        guard let spin = topTurns.first(where: { turn in
            CubeSlots.slot(holding: piece, in: gripped.applying(turn)) == aboveIt
        }) else {
            throw SolverError.stuck("Couldn't bring a corner over its gap.")
        }

        var working = gripped.applying(spin)
        var moves: [Move] = []
        for _ in 0..<6 {
            if frontRight.isSolved(in: working) {
                return CornerPlan(grip: grip, spin: spin, moves: moves, places: true)
            }
            working = working.applying(righty)
            moves += righty
        }
        throw SolverError.stuck("Righty didn't drop that corner in.")
    }

    private static func solveBottomCorners(_ builder: Builder) throws {
        builder.begin(.whiteCorners)

        for _ in 0..<20 {
            let unsolved = CubeSlots.bottomCorners.filter { !$0.isSolved(in: builder.state) }
            if unsolved.isEmpty { return }

            var plans: [(slot: CubeSlot, plan: CornerPlan)] = []
            for slot in unsolved {
                plans.append((slot, try cornerPlan(for: slot, in: builder.state)))
            }
            // Never take a corner out of the bottom while one is waiting to go
            // in, and among those that can go in, take the shortest.
            let ready = plans.filter(\.plan.places)
            let choices = ready.isEmpty ? plans : ready
            guard let chosen = choices.min(by: { $0.plan.length < $1.plan.length }) else {
                throw SolverError.stuck("Lost track of a white corner.")
            }

            let piece = Set(chosen.slot.faces)
            if !chosen.plan.places {
                // Which of the two ways it is stuck, so the words match what
                // the child is looking at.
                let inItsOwnGap = CubeSlots.slot(holding: piece, in: builder.state)
                    == chosen.slot
                builder.step(piece: piece, home: piece, places: false,
                             grip: "This one is down in the bottom already. Turn the "
                                 + "cube so it's at the front right.",
                             outcome: inItsOwnGap
                                 ? "There's no white corner waiting up top, and this "
                                 + "one is in its gap facing the wrong way. One righty "
                                 + "lifts it out, and then we can put it back in properly."
                                 : "There's no white corner waiting up top, so we have "
                                 + "to bring one up. One righty lifts this one out, and "
                                 + "then we can put it in its own gap.")
            } else {
                // Listed in the order `step` declares them; the order the child
                // does them in is the order they are performed, just below:
                // turn the cube first, then spin the top.
                builder.step(piece: piece, home: piece,
                             spin: "Spin the top until the corner sits directly over "
                                 + "its gap, its colours above the middles that match.",
                             grip: "Look at the three middles around this corner's "
                                 + "gap — those are its colours. Turn the cube so that "
                                 + "gap is at the front right.",
                             outcome: chosen.plan.moves.count <= 4
                                 ? "It's already the right way round — one righty "
                                 + "drops it straight in."
                                 : "Now do righty over and over until it drops in. It "
                                 + "only goes in the right way round, so it sorts "
                                 + "itself out.",
                             algorithmName: "righty")
            }
            builder.perform(chosen.plan.grip)
            builder.perform(chosen.plan.spin)
            builder.running()
            builder.perform(chosen.plan.moves)
        }
        throw SolverError.stuck("Couldn't finish the white corners.")
    }

    // MARK: - Stage 4, the middle row

    private static func solveMiddleRow(_ builder: Builder) throws {
        builder.begin(.middleRow)
        guard let frontTop = CubeSlots.slot(with: [.U, .F]) else { return }

        for _ in 0..<20 {
            let unsolved = CubeSlots.middleEdges.filter { !$0.isSolved(in: builder.state) }
            if unsolved.isEmpty { return }

            // Count what each one would cost rather than taking the first that
            // comes to hand. The insert is always the same eight moves, so the
            // difference is entirely in the lining up, and an edge already
            // sitting over the middle that matches it needs none of it.
            var candidate: CubeSlot?
            var cheapest = Int.max
            for slot in CubeSlots.topEdges {
                let colours = slot.colours(in: builder.state)
                if colours.contains(.U) { continue }        // belongs in the last layer
                guard let face = slot.sideFaces.first,
                      let side = slot.sticker(on: face, in: builder.state) else { continue }
                let cost = topTurn(from: face, to: side).count + turnToFront(side).count
                if cost < cheapest {
                    cheapest = cost
                    candidate = slot
                }
            }

            guard let slot = candidate,
                  let face = slot.sideFaces.first,
                  let side = slot.sticker(on: face, in: builder.state) else {
                // Everything left is trapped in the middle row: pop one out.
                let stuck = Set(unsolved[0].colours(in: builder.state))
                builder.step(piece: stuck, home: stuck, places: false,
                             grip: "This edge is in the middle row but in the wrong "
                                 + "place. Turn the cube so it's at the front right.",
                             outcome: "Sending another edge in pushes this one out to "
                                    + "the top.")
                builder.perform(turnToFrontRight(unsolved[0].faces))
                builder.running()
                builder.perform(insertRight)
                continue
            }

            let piece = Set(slot.colours(in: builder.state))
            builder.step(piece: piece, home: piece,
                         spin: "Spin the top until this colour sits on the middle that "
                             + "matches it, making a little T.",
                         grip: "Turn the cube so that side is facing you.",
                         outcome: cheapest == 0
                             ? "This one's already lined up — send the top away from "
                             + "the gap and it drops in."
                             : "Send the top away from the gap, and the edge drops in.")
            builder.perform(topTurn(from: face, to: side))
            builder.perform(turnToFront(side))
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

    /// The three shapes the cross move is taught from, and nothing else.
    ///
    /// A dot, an L pointing at the back and the left, or a line lying left to
    /// right. One rule, three pictures, and the same six moves turns each one
    /// into the next. Measured against letting the search go where it liked:
    /// exactly the same number of goes, 1.62 on average, so teaching it
    /// properly is free.
    private static func crossReady(_ state: CubeState) -> Bool {
        let showing = Set(CubeSlots.topEdges
            .filter { $0.sticker(on: .U, in: state) == .U }
            .map(\.name))
        return showing.isEmpty || showing == ["UB", "UL"] || showing == ["UL", "UR"]
    }

    /// Where the fish is taught from.
    ///
    /// One corner already yellow on top: put that one at the front left. None
    /// yet, or two: turn the top until the front-left corner has its yellow
    /// looking left. Also free — the same 2.25 goes on average as letting the
    /// search choose.
    private static func fishReady(_ state: CubeState) -> Bool {
        let up = CubeSlots.topCorners.filter { $0.sticker(on: .U, in: state) == .U }
        if up.count == 1 { return up[0].name == "UFL" }
        guard let frontLeft = CubeSlots.slot(with: [.U, .F, .L]) else { return false }
        return frontLeft.face(showing: .U, in: state) == .L
    }

    /// Where the edge swap is taught from: the top edge that is already home
    /// sits at the back.
    ///
    /// If none of them is home yet, any turn will do — the first go puts one
    /// right. Measured, this costs 0.16 of a go on average, and it makes the
    /// instruction true, which it was not: left to find its own way the search
    /// ran the move with the finished edge at the front as often as the back.
    private static func edgesReady(_ state: CubeState) -> Bool {
        let home = CubeSlots.topEdges.filter { $0.isSolved(in: state) }
        return home.count != 1 || home[0].name == "UB"
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
                               ready: (CubeState) -> Bool = { _ in true },
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
                let lined = node.state.applying(turn)
                // Only from a position the child has been taught to line up.
                // Without this the search takes whatever shortcut it finds, and
                // then the app is telling a child to look for one shape while
                // quietly working from another.
                guard ready(lined) else { continue }
                let next = lined.applying(algorithm)
                let path = node.path + [Round(turn: turn, algorithm: algorithm)]
                if goal(next) { return path }
                if seen.contains(next) { continue }
                seen.insert(next)
                queue.append((next, path))
            }
        }
        throw SolverError.stuck("Couldn't work out that step. Let's scan the cube again.")
    }

    /// Run a stage as a series of rounds, one step each.
    private static func rounds(_ builder: Builder,
                               algorithm: [Move],
                               goal: (CubeState) -> Bool,
                               ready: (CubeState) -> Bool = { _ in true },
                               named: String,
                               spin: String,
                               outcome: String) throws {
        for round in try search(from: builder.state, algorithm: algorithm,
                                ready: ready, goal: goal) {
            builder.step(spin: spin, outcome: outcome, algorithmName: named)
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
