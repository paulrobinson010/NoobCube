import Foundation

/// Last-layer algorithms for the faster methods.
///
/// Face turns only. Cubers usually write some of these with wide or slice
/// turns, but a smart cube reports face turns and a child copying the arrows
/// turns faces, so every one here is written the way it is actually done.
///
/// Each algorithm is checked in `Tools/CubeReference/last_layer.py`: it keeps
/// the first two layers, it solves its own case, and between them the tables
/// cover all 62,208 last layers there are. These tables are a copy of those.
enum LastLayer {

    struct Algorithm: Sendable {
        let name: String
        let moves: [Move]

        init(_ name: String, _ moves: String) {
            self.name = name
            self.moves = Move.parse(moves)
        }
    }

    /// One look: turn the top, then run an algorithm.
    struct Look: Sendable {
        let name: String
        let turn: [Move]
        let moves: [Move]
    }

    // MARK: - Faster: two looks to orient, two to permute

    /// Making the yellow cross.
    static let edges: [Algorithm] = [
        Algorithm("the line", "F R U R' U' F'"),
        Algorithm("the hook", "F U R U' R' F'"),
    ]

    /// The yellow face, once the cross is made.
    static let yellowFace: [Algorithm] = [
        Algorithm("Sune", "R U R' U R U2 R'"),
        Algorithm("Anti-Sune", "R U2 R' U' R U' R'"),
        Algorithm("the H", "R U R' U R U' R' U R U2 R'"),
        Algorithm("the Pi", "R U2 R2 U' R2 U' R2 U2 R"),
        Algorithm("headlights", "R2 D R' U2 R D' R' U2 R'"),
        Algorithm("the T", "L F R' F' L' F R F'"),
        Algorithm("the bow tie", "R' F R B' R' F' R B"),
    ]

    /// Two-look PLL, first look: the corners.
    static let cornerSwaps: [Algorithm] = [
        Algorithm("the T-perm", "R U R' U' R' F R2 U' R' U' R U R' F'"),
        Algorithm("the Y-perm", "F R U' R' U' R U R' F' R U R' U' R' F R F'"),
    ]

    /// Two-look PLL, second look: the edges.
    static let edgeCycles: [Algorithm] = [
        Algorithm("the Ua-perm", "R U' R U R U R U' R' U' R2"),
        Algorithm("the Ub-perm", "R2 U R U R' U' R' U' R' U R'"),
        Algorithm("the H-perm", "R2 U2 R U2 R2 U2 R2 U2 R U2 R2"),
        Algorithm("the Z-perm", "R' U' R U' R U R U' R' U R U R2 U' R' U2"),
    ]

    // MARK: - Speedcuber: one look each

    /// All 57, by their usual numbers. Where the usual algorithm needs wide or
    /// slice turns, this is the shortest pair of checked ones that does the
    /// same job.
    static let oll: [Algorithm] = ollTable.map { Algorithm(ollName($0.0), $0.1) }

    private static let ollTable: [(Int, String)] = [
        (1, "R U2 R2 F R F' U2 R' F R F'"),
        (2, "F U R U' R' F' R' U' R' F R F' U R"),
        (3, "F' U' L' U L F U' F R U R' U' F'"),
        (4, "F' U' L' U L F U F R U R' U' F'"),
        (5, "F' U' L' U L F U' F' U' L' U L F"),
        (6, "R U2 R' U' R U' R' U' F U R U' R' F'"),
        (7, "F R' F' R U2 R U2 R'"),
        (8, "R U2 R' U2 R' F R F'"),
        (9, "R U R' U' R' F R2 U R' U' F'"),
        (10, "R U R' U R' F R F' R U2 R'"),
        (11, "F' U' L' U L F U R B' R2 F R2 B R2 F' R"),
        (12, "F R U R' U' F' U F R U R' U' F'"),
        (13, "F U R U' R2 F' R U R U' R'"),
        (14, "R' F R U R' F' R F U' F'"),
        (15, "F U R U' R' F' U F' U' L' U L F"),
        (16, "F' U' L' U L F U' F U R U' R' F'"),
        (17, "F R' F' R U2 R U' B U' B' R'"),
        (18, "F R' F' R U R U' R' U F R U R' U' F'"),
        (19, "F R U R' U' F' R U2 R2 F R F' R U2 R'"),
        (20, "F' U' L' U L F R' U' R' F R F' U R"),
        (21, "R U R' U R U' R' U R U2 R'"),
        (22, "R U2 R2 U' R2 U' R2 U2 R"),
        (23, "R2 D R' U2 R D' R' U2 R'"),
        (24, "L F R' F' L' F R F'"),
        (25, "R' F R B' R' F' R B"),
        (26, "R U2 R' U' R U' R'"),
        (27, "R U R' U R U2 R'"),
        (28, "L F R' F' L' R U R U' R'"),
        (29, "R U R' U' R U' R' F' U' F R U R'"),
        (30, "F R' F R2 U' R' U' R U R' F2"),
        (31, "R' U' F U R U' R' F' R"),
        (32, "L U F' U' L' U L F L'"),
        (33, "R U R' U' R' F R F'"),
        (34, "R U R2 U' R' F R U R U' F'"),
        (35, "R U2 R2 F R F' R U2 R'"),
        (36, "L' U' L U' L' U L U L F' L' F"),
        (37, "F R' F' R U R U' R'"),
        (38, "R U R' U R U' R' U' R' F R F'"),
        (39, "L F' L' U' L U F U' L'"),
        (40, "R' F R U R' U' F' U R"),
        (41, "R U R' U R U2 R' F R U R' U' F'"),
        (42, "R' U' R U' R' U2 R F R U R' U' F'"),
        (43, "F' U' L' U L F"),
        (44, "F U R U' R' F'"),
        (45, "F R U R' U' F'"),
        (46, "R' U' R' F R F' U R"),
        (47, "F' L' U' L U L' U' L U F"),
        (48, "F R U R' U' R U R' U' F'"),
        (49, "R B' R2 F R2 B R2 F' R"),
        (50, "R' F R2 B' R2 F' R2 B R'"),
        (51, "F U R U' R' U R U' R' F'"),
        (52, "R U R' U R U' B U' B' R'"),
        (53, "R U2 R2 U' R2 U' R2 U R' F R F' U R"),
        (54, "F U R U' R2 F' R U2 R' F R F' R U2 R'"),
        (55, "R U2 R2 U' R U' R' U2 F R F'"),
        (56, "F R U R' U' F' L F R' F' L' F R F'"),
        (57, "F R' F' R2 U' R' F' U' F R U R'"),
    ]

    /// The ones with a name everybody uses get it said as well as the number.
    private static func ollName(_ number: Int) -> String {
        let nicknames = [21: "the H", 22: "the Pi", 23: "headlights", 24: "the T",
                         25: "the bow tie", 26: "Anti-Sune", 27: "Sune"]
        if let nickname = nicknames[number] { return "OLL \(number), \(nickname)" }
        return "OLL \(number)"
    }

    static let pll: [Algorithm] = [
        Algorithm("the Aa-perm", "R' F R' B2 R F' R' B2 R2"),
        Algorithm("the Ab-perm", "R B' R F2 R' B R F2 R2"),
        Algorithm("the E-perm", "R B' R' F R B R' F' R B R' F R B' R' F'"),
        Algorithm("the F-perm", "R' U' F' R U R' U' R' F R2 U' R' U' R U R' U R"),
        Algorithm("the Ga-perm", "R2 U R' U R' U' R U' R2 U' D R' U R D'"),
        Algorithm("the Gb-perm", "R' U' R U D' R2 U R' U R U' R U' R2 D"),
        Algorithm("the Gc-perm", "R2 U' R U' R U R' U R2 U D' R U' R' D"),
        Algorithm("the Gd-perm", "R U R' U' D R2 U' R U' R' U R' U R2 D'"),
        Algorithm("the H-perm", "R2 U2 R U2 R2 U2 R2 U2 R U2 R2"),
        Algorithm("the Ja-perm", "R' U L' U2 R U' R' U2 R L"),
        Algorithm("the Jb-perm", "R U R' F' R U R' U' R' F R2 U' R'"),
        Algorithm("the Na-perm", "R U R' U R U R' F' R U R' U' R' F R2 U' R' U2 R U' R'"),
        Algorithm("the Nb-perm", "R' U R U' R' F' U' F R U R' F R' F' R U' R"),
        Algorithm("the Ra-perm", "R U' R' U' R U R D R' U' R D' R' U2 R'"),
        Algorithm("the Rb-perm", "R2 F R U R U' R' F' R U2 R' U2 R"),
        Algorithm("the T-perm", "R U R' U' R' F R2 U' R' U' R U R' F'"),
        Algorithm("the Ua-perm", "R U' R U R U R U' R' U' R2"),
        Algorithm("the Ub-perm", "R2 U R U R' U' R' U' R' U R'"),
        Algorithm("the V-perm", "R' U R' U' R D' R' D R' U D' R2 U' R2 D R2"),
        Algorithm("the Y-perm", "F R U' R' U' R U R' F' R U R' U' R' F R F'"),
        Algorithm("the Z-perm", "R' U' R U' R U R U' R' U R U R2 U' R' U2"),
    ]

    // MARK: - What the top looks like

    private static let topTurns = BeginnerSolver.topTurns
    private static let topEdgeStickers = [1, 3, 5, 7]
    /// The two top-row corner stickers on each side face.
    private static let topCornerSideStickers: [Int] =
        [Face.R, .F, .L, .B].flatMap { [$0.rawValue * 9, $0.rawValue * 9 + 2] }

    static func isOriented(_ state: CubeState) -> Bool {
        Face.U.faceletIndices.allSatisfy { state[$0] == .U }
    }

    static func isCrossMade(_ state: CubeState) -> Bool {
        topEdgeStickers.allSatisfy { state[$0] == .U }
    }

    static func isSolvedIgnoringTopTurn(_ state: CubeState) -> Bool {
        topTurns.contains { state.applying($0).isSolved }
    }

    /// The corners belong together, however the top happens to be turned.
    static func cornersPlacedIgnoringTopTurn(_ state: CubeState) -> Bool {
        topTurns.contains { turn in
            let turned = state.applying(turn)
            return topCornerSideStickers.allSatisfy { turned[$0] == Face.of(facelet: $0) }
        }
    }

    // MARK: - Choosing

    /// The first algorithm in the table, after the first turn of the top, that
    /// reaches the goal. Top turns in the order none, U, U2, U', then table
    /// order — the same as the reference, so both pick the same one.
    static func firstThat(_ state: CubeState,
                          in table: [Algorithm],
                          reaches goal: (CubeState) -> Bool) -> Look? {
        for turn in topTurns {
            let turned = state.applying(turn)
            for algorithm in table where goal(turned.applying(algorithm.moves)) {
                return Look(name: algorithm.name, turn: turn, moves: algorithm.moves)
            }
        }
        return nil
    }

    /// Yellow cross, then yellow face. With no yellow edges on top (the dot)
    /// no single one makes the cross, so the line goes first with the top as
    /// it is — that always leaves a hook or a line for the second go.
    static func orientInTwoLooks(_ state: CubeState) throws -> [Look] {
        var state = state
        var looks: [Look] = []
        for _ in 0..<2 where !isCrossMade(state) {
            let look = firstThat(state, in: edges, reaches: isCrossMade)
                ?? Look(name: edges[0].name, turn: [], moves: edges[0].moves)
            looks.append(look)
            state = state.applying(look.turn + look.moves)
        }
        guard isCrossMade(state) else { throw SolverError.stuck("The yellow cross wouldn't come.") }
        if !isOriented(state) {
            guard let look = firstThat(state, in: yellowFace, reaches: isOriented) else {
                throw SolverError.stuck("Couldn't find a move for that yellow shape.")
            }
            looks.append(look)
        }
        return looks
    }

    static func orientInOneLook(_ state: CubeState) throws -> [Look] {
        if isOriented(state) { return [] }
        guard let look = firstThat(state, in: oll, reaches: isOriented) else {
            throw SolverError.stuck("Couldn't find a move for that yellow shape.")
        }
        return [look]
    }

    static func permuteInTwoLooks(_ state: CubeState) throws -> [Look] {
        var state = state
        var looks: [Look] = []
        if !cornersPlacedIgnoringTopTurn(state) {
            guard let look = firstThat(state, in: cornerSwaps, reaches: cornersPlacedIgnoringTopTurn) else {
                throw SolverError.stuck("Couldn't find a way to swap those corners.")
            }
            looks.append(look)
            state = state.applying(look.turn + look.moves)
        }
        if !isSolvedIgnoringTopTurn(state) {
            guard let look = firstThat(state, in: edgeCycles, reaches: isSolvedIgnoringTopTurn) else {
                throw SolverError.stuck("Couldn't find a way to swap those edges.")
            }
            looks.append(look)
        }
        return looks
    }

    static func permuteInOneLook(_ state: CubeState) throws -> [Look] {
        if isSolvedIgnoringTopTurn(state) { return [] }
        guard let look = firstThat(state, in: pll, reaches: isSolvedIgnoringTopTurn) else {
            throw SolverError.stuck("Couldn't find a way to finish the top.")
        }
        return [look]
    }
}
