import Foundation

/// The faster methods: the white cross straight onto the bottom, the first two
/// layers a corner-and-edge pair at a time, then the last layer by algorithm —
/// in four looks (Faster) or two (Speedcuber).
///
/// The cross and the pairs are found by search rather than from a table. Each
/// piece is followed by one of its stickers, and a short iterative-deepening
/// search finds the fewest turns that put it home without disturbing anything
/// already done. The gap is always turned to the front first, so the turns
/// are ones a child can see: the top, the right and the front.
///
/// A direct port of `Tools/CubeReference/advanced.py`, which is where it is
/// checked over thousands of cubes. Change it there first.
enum PairsSolver {

    // MARK: - Entry point

    static func solve(_ state: CubeState,
                      lastLayerInOneLook: Bool,
                      whiteFace: Face = .D) throws -> SolvePlan {
        let problems = state.validate()
        guard problems.isEmpty else { throw SolverError.notSolvable(problems) }

        let builder = BeginnerSolver.Builder(state: state)
        builder.begin(.hold)
        builder.step(grip: "Turn the whole cube so white is underneath and yellow is on top.",
                     outcome: "Now left and right mean the same thing to both of us.")
        builder.perform(BeginnerSolver.rotationBringingWhiteDown(from: whiteFace))

        try solveCross(builder)
        try solvePairs(builder)
        try solveLastLayer(builder, inOneLook: lastLayerInOneLook)

        guard builder.state.isSolved else {
            throw SolverError.stuck("Something went wrong working that one out. Let's scan again.")
        }
        return SolvePlan(start: state, stages: BeginnerSolver.assemble(builder, from: state))
    }

    // MARK: - Following stickers

    /// Where the sticker at each index goes when a move is turned.
    private static let destinations: [Move: [Int]] = {
        var table: [Move: [Int]] = [:]
        for (move, permutation) in CubeGeometry.allPermutations {
            var destination = [Int](repeating: 0, count: 54)
            for (landing, source) in permutation.enumerated() {
                destination[source] = landing
            }
            table[move] = destination
        }
        return table
    }()

    private static func turns(of faces: [MoveBase]) -> [Move] {
        faces.flatMap { [Move($0, .clockwise), Move($0, .counterClockwise), Move($0, .half)] }
    }

    /// The cross is put in from the front, so the back is never needed, and
    /// the bottom only when nothing shorter works.
    private static let crossTurns: [[Move]] = [turns(of: [.U, .R, .F, .L]),
                                               turns(of: [.U, .R, .F, .L, .D])]
    /// A pair goes in at the front right, using the three faces you can see.
    private static let pairTurns = turns(of: [.U, .R, .F])

    /// The square a piece's `colour` sticker sits on when the piece is home.
    private static func home(of colours: Set<Face>, colour: Face) -> Int {
        guard let slot = CubeSlots.slot(with: colours),
              let position = slot.faces.firstIndex(of: colour) else { return 0 }
        return slot.indices[position]
    }

    /// Where a piece's `colour` sticker is now.
    private static func whereIs(_ colours: Set<Face>, colour: Face, in state: CubeState) -> Int {
        guard let slot = CubeSlots.slot(holding: colours, in: state) else { return 0 }
        return slot.indices.first { state[$0] == colour } ?? 0
    }

    // MARK: - Search

    private static let unreachable = UInt8.max

    private static func key(_ positions: [Int]) -> Int {
        positions.reduce(0) { $0 * 54 + $1 }
    }

    /// Fewest turns from every arrangement of these stickers back to `homes`.
    /// One or two stickers, so the table is at most 54 × 54.
    private static func distanceTable(homes: [Int], turns: [Move]) -> [UInt8] {
        var size = 1
        for _ in homes { size *= 54 }
        var distance = [UInt8](repeating: unreachable, count: size)
        distance[key(homes)] = 0
        var queue = [homes]
        var head = 0
        while head < queue.count {
            let at = queue[head]
            head += 1
            let next = distance[key(at)] + 1
            for move in turns {
                guard let destination = destinations[move] else { continue }
                let moved = at.map { destination[$0] }
                if distance[key(moved)] == unreachable {
                    distance[key(moved)] = next
                    queue.append(moved)
                }
            }
        }
        return distance
    }

    /// Shortest turns taking the stickers at `start` to `homes`.
    ///
    /// `groups` are the stickers whose joint distance home is looked up and
    /// used as a lower bound, which is what keeps the search small. `goal`, if
    /// given, replaces "everything home" (for lifting a piece out of the way).
    /// Nil when nothing within `limit` turns works.
    private static func search(from start: [Int],
                               to homes: [Int],
                               groups: [[Int]],
                               turns: [Move],
                               limit: Int,
                               goal: (([Int]) -> Bool)? = nil) -> [Move]? {
        let tables = groups.map { group in
            (group, distanceTable(homes: group.map { homes[$0] }, turns: turns))
        }
        let done: ([Int]) -> Bool = goal ?? { $0 == homes }
        let far = limit + 1

        func bound(_ at: [Int]) -> Int {
            var most = 0
            for (group, table) in tables {
                let found = table[key(group.map { at[$0] })]
                most = max(most, found == unreachable ? far : Int(found))
            }
            return most
        }

        var path: [Move] = []

        func dig(_ at: [Int], _ depth: Int, _ last: MoveBase?) -> Bool {
            if depth == 0 { return done(at) }
            if bound(at) > depth { return false }
            for move in turns where move.base != last {
                guard let destination = destinations[move] else { continue }
                path.append(move)
                if dig(at.map { destination[$0] }, depth - 1, move.base) { return true }
                path.removeLast()
            }
            return false
        }

        for depth in 0...limit {
            if bound(start) > depth { continue }
            if dig(start, depth, nil) { return path }
        }
        return nil
    }

    private static func splitLeading(_ moves: [Move], _ base: MoveBase) -> (lead: [Move], rest: [Move]) {
        let count = moves.prefix { $0.base == base }.count
        return (Array(moves.prefix(count)), Array(moves.dropFirst(count)))
    }

    // MARK: - The cross

    private static let crossSides: [Face] = [.F, .R, .B, .L]

    private static func crossEdgeHome(_ state: CubeState, _ side: Face) -> Bool {
        CubeSlots.slot(with: [.D, side])?.isSolved(in: state) ?? false
    }

    /// Turn the cube so this edge's side is in front, then the fewest turns
    /// that put it home and leave the edges already in the cross where they are.
    private static func crossPlan(_ state: CubeState, side: Face) throws -> (grip: [Move], moves: [Move]) {
        let grip = BeginnerSolver.turnToFront(side)
        let turned = state.applying(grip)
        let kept = crossSides.filter { $0 != .F && crossEdgeHome(turned, $0) }
        let tracked: [Set<Face>] = [Set([Face.D, .F])] + kept.map { Set([Face.D, $0]) }
        let start = tracked.map { whereIs($0, colour: .D, in: turned) }
        let homes = tracked.map { home(of: $0, colour: .D) }
        let groups = tracked.indices.map { [$0] }
        for turns in crossTurns {
            if let moves = search(from: start, to: homes, groups: groups, turns: turns, limit: 8) {
                return (grip, moves)
            }
        }
        throw SolverError.stuck("Couldn't work out how to put that cross edge in.")
    }

    private static func solveCross(_ builder: BeginnerSolver.Builder) throws {
        builder.begin(.cross)
        for _ in 0..<5 {
            let waiting = crossSides.filter { !crossEdgeHome(builder.state, $0) }
            if waiting.isEmpty { return }
            var plans: [Face: (grip: [Move], moves: [Move])] = [:]
            for side in waiting {
                plans[side] = try crossPlan(builder.state, side: side)
            }
            // The cheapest first; turning the whole cube costs nothing.
            var side = waiting[0]
            for other in waiting where plans[other]!.moves.count < plans[side]!.moves.count {
                side = other
            }
            let plan = plans[side]!
            let (spin, rest) = splitLeading(plan.moves, .U)
            let piece: Set<Face> = [.D, side]
            builder.step(piece: piece, home: piece,
                         spin: "Spin the top until the edge is above its gap.",
                         grip: "Turn the cube so the middle that matches this edge is "
                             + "facing you. The edge goes underneath it.",
                         turn: "Turn a side to bring it round.",
                         outcome: rest.count <= 2
                            ? "It drops straight in, white on the bottom and its colour "
                              + "next to the middle that matches."
                            : "That brings it round and down into its place. Anything "
                              + "already in the cross that moves comes straight back.")
            builder.perform(plan.grip)
            builder.perform(spin)
            builder.running()
            builder.perform(rest)
        }
        throw SolverError.stuck("The white cross wouldn't finish. Let's scan again.")
    }

    // MARK: - The pairs

    private static let gaps: [[Face]] = [[.F, .R], [.F, .L], [.B, .L], [.B, .R]]

    private static func pairSolved(_ state: CubeState, _ sides: [Face]) -> Bool {
        let corner = CubeSlots.slot(with: Set(sides + [.D]))
        let edge = CubeSlots.slot(with: Set(sides))
        return (corner?.isSolved(in: state) ?? false) && (edge?.isSolved(in: state) ?? false)
    }

    /// The finished things at the front right that the top, right and front
    /// can disturb: two cross edges, and the neighbouring pairs if they are
    /// done. Each piece is followed by one colour.
    private static func keptForPairs(_ state: CubeState) -> (pieces: [(Set<Face>, Face)], groups: [[Int]]) {
        var kept: [(Set<Face>, Face)] = [([.D, .F], .D), ([.D, .R], .D)]
        var groups: [[Int]] = [[0, 1]]
        for sides in [[Face.F, .L], [.B, .R]] where pairSolved(state, sides) {
            let base = kept.count
            kept.append((Set(sides + [.D]), .D))
            kept.append((Set(sides), sides[0]))
            groups.append([base, base + 1])
        }
        return (kept, groups)
    }

    private static func pairPlan(_ state: CubeState, gap: [Face], limit: Int) -> (grip: [Move], moves: [Move])? {
        let grip = BeginnerSolver.turnToFrontRight(gap)
        let turned = state.applying(grip)
        let kept = keptForPairs(turned)
        let tracked: [(Set<Face>, Face)] = [([.D, .F, .R], .D), ([.F, .R], .F)] + kept.pieces
        let start = tracked.map { whereIs($0.0, colour: $0.1, in: turned) }
        let homes = tracked.map { home(of: $0.0, colour: $0.1) }
        let groups = [[0, 1]] + kept.groups.map { $0.map { $0 + 2 } }
        guard let moves = search(from: start, to: homes, groups: groups,
                                 turns: pairTurns, limit: limit) else { return nil }
        return (grip, moves)
    }

    /// Nothing can go straight in: a piece is stuck in the gap diagonally
    /// opposite its own. Lift one out to the top, the shortest way.
    private static func freePlan(_ state: CubeState) throws -> (grip: [Move], moves: [Move], piece: Set<Face>) {
        let top = Set(Face.U.faceletIndices).union(
            [Face.R, .F, .L, .B].flatMap { ($0.rawValue * 9)..<($0.rawValue * 9 + 3) })
        var found: (grip: [Move], moves: [Move], piece: Set<Face>)?

        for gap in gaps {
            let grip = BeginnerSolver.turnToFrontRight(gap)
            let turned = state.applying(grip)
            if pairSolved(turned, [.F, .R]) { continue }
            guard let cornerSlot = CubeSlots.slot(with: [.D, .F, .R]),
                  let edgeSlot = CubeSlots.slot(with: [.F, .R]) else { continue }
            let corner = cornerSlot.piece(in: turned)
            let edge = edgeSlot.piece(in: turned)
            var stuck: [(Set<Face>, Face)] = []
            let byLetter: (Face, Face) -> Bool = { $0.letter < $1.letter }
            let cornerColour: Face? = corner.contains(.D) ? Face.D : corner.min(by: byLetter)
            if !corner.contains(.U), let cornerColour {
                stuck.append((corner, cornerColour))
            }
            if !edge.contains(.U), let colour = edge.min(by: byLetter) {
                stuck.append((edge, colour))
            }
            guard let piece = stuck.first else { continue }

            let kept = keptForPairs(turned)
            let tracked = [piece] + kept.pieces
            let start = tracked.map { whereIs($0.0, colour: $0.1, in: turned) }
            let homes = [start[0]] + kept.pieces.map { home(of: $0.0, colour: $0.1) }
            let groups = kept.groups.map { $0.map { $0 + 1 } }
            let keptHomes = Array(homes.dropFirst())
            let lifted: ([Int]) -> Bool = { at in
                top.contains(at[0]) && Array(at.dropFirst()) == keptHomes
            }
            if let moves = search(from: start, to: homes, groups: groups,
                                  turns: pairTurns, limit: 5, goal: lifted),
               found == nil || moves.count < found!.moves.count {
                found = (grip, moves, piece.0)
            }
        }
        guard let found else { throw SolverError.stuck("Couldn't work out the next pair.") }
        return found
    }

    private static func solvePairs(_ builder: BeginnerSolver.Builder) throws {
        builder.begin(.pairs)
        for _ in 0..<12 {
            let unsolved = gaps.filter { !pairSolved(builder.state, $0) }
            if unsolved.isEmpty { return }

            var cheapest: (gap: [Face], grip: [Move], moves: [Move])?
            var limit = 13
            for gap in unsolved {
                if let plan = pairPlan(builder.state, gap: gap, limit: limit),
                   cheapest == nil || plan.moves.count < cheapest!.moves.count {
                    cheapest = (gap, plan.grip, plan.moves)
                    limit = plan.moves.count - 1
                }
            }

            guard let best = cheapest else {
                let free = try freePlan(builder.state)
                builder.step(piece: free.piece, home: free.piece, places: false,
                             grip: "This piece is stuck in the wrong gap. Turn the cube "
                                 + "so that gap is at the front right.",
                             outcome: "That lifts it out to the top, where it can be paired up.")
                builder.perform(free.grip)
                builder.running()
                builder.perform(free.moves)
                continue
            }

            let corner = Set(best.gap + [.D])
            let (spin, rest) = splitLeading(best.moves, .U)
            builder.step(piece: corner, home: corner,
                         spin: "Spin the top to get the corner and its edge ready.",
                         grip: "Find the gap this corner belongs in: the two middles "
                             + "beside it are its other colours. Turn the cube so that "
                             + "gap is at the front right.",
                         outcome: rest.count > 3
                            ? "The corner and its edge join up, then drop into the gap "
                              + "together. Anything else that moves comes straight back."
                            : "The corner and its edge drop into the gap together.",
                         algorithmName: "pairing up")
            builder.perform(best.grip)
            builder.perform(spin)
            builder.running()
            builder.perform(rest)
        }
        throw SolverError.stuck("The first two layers wouldn't finish. Let's scan again.")
    }

    // MARK: - The last layer

    private static func perform(_ looks: [LastLayer.Look],
                                on builder: BeginnerSolver.Builder,
                                spin: String,
                                outcome: String) {
        for look in looks {
            builder.step(spin: spin, outcome: outcome, algorithmName: look.name)
            builder.perform(look.turn)
            builder.running()
            builder.perform(look.moves)
        }
    }

    private static func solveLastLayer(_ builder: BeginnerSolver.Builder, inOneLook: Bool) throws {
        if inOneLook {
            builder.begin(.oll)
            perform(try LastLayer.orientInOneLook(builder.state), on: builder,
                    spin: "Turn the top so the yellow shape lines up for this move. "
                        + "The arrow shows which way.",
                    outcome: "The whole top goes yellow in one go.")
            builder.begin(.pll)
            perform(try LastLayer.permuteInOneLook(builder.state), on: builder,
                    spin: "Turn the top so it lines up for this move. The arrow shows "
                        + "which way.",
                    outcome: "Everything on top slides into place in one go.")
        } else {
            let orienting = try LastLayer.orientInTwoLooks(builder.state)
            let edgeNames = Set(LastLayer.edges.map(\.name))
            let edges = orienting.prefix { edgeNames.contains($0.name) }
            builder.begin(.topCross)
            perform(Array(edges), on: builder,
                    spin: "Turn the top until the yellow line lies left to right, or "
                        + "the hook points at the back and the left.",
                    outcome: "That makes more of the yellow cross.")
            builder.begin(.topFace)
            perform(Array(orienting.dropFirst(edges.count)), on: builder,
                    spin: "Turn the top so the yellow shape lines up for this move. "
                        + "The arrow shows which way.",
                    outcome: "The whole top goes yellow.")

            let permuting = try LastLayer.permuteInTwoLooks(builder.state)
            let cornerNames = Set(LastLayer.cornerSwaps.map(\.name))
            let corners = permuting.prefix { cornerNames.contains($0.name) }
            builder.begin(.topCorners)
            perform(Array(corners), on: builder,
                    spin: "If two corners on one side match each other, turn the top "
                        + "until they're on the left.",
                    outcome: "Now the corners all belong together.")
            builder.begin(.topEdges)
            perform(Array(permuting.dropFirst(corners.count)), on: builder,
                    spin: "Turn the top until the side that's already right is at "
                        + "the back.",
                    outcome: "The edges swap round into their places.")
        }
        let last = BeginnerSolver.finalTopTurn(builder.state)
        if !last.isEmpty {
            builder.step(spin: "One last spin of the top.",
                         outcome: "And that's the whole cube.")
            builder.perform(last)
        }
    }
}
