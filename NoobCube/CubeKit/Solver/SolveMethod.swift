import Foundation

/// How the cube gets solved: the same cube, three ways of thinking about it.
///
/// Beginner is layer by layer from the daisy, with seven moves to learn.
/// Faster puts the white cross straight on the bottom, fills the first two
/// layers a pair at a time, and finishes the top in four looks. Speedcuber is
/// the same start with the top finished in two looks, the way the fastest
/// people do it.
enum SolveMethod: String, CaseIterable, Codable, Hashable, Sendable {
    case beginner
    case faster
    case speedcuber

    /// The name on the button.
    var title: String {
        switch self {
        case .beginner:   return "Beginner"
        case .faster:     return "Faster"
        case .speedcuber: return "Speedcuber"
        }
    }

    /// One line under the name.
    var subtitle: String {
        switch self {
        case .beginner:   return "Layer by layer, from the daisy"
        case .faster:     return "Pairs, then the top in four looks"
        case .speedcuber: return "Pairs, then the top in two looks"
        }
    }

    /// What it is, said aloud to someone who can't read the button.
    var spoken: String {
        switch self {
        case .beginner:
            return "Beginner starts with a daisy and does the cube one layer at a time. It's the best one to learn first."
        case .faster:
            return "Faster makes the white cross straight on the bottom, puts pieces in two at a time, and finishes the top in four goes."
        case .speedcuber:
            return "Speedcuber is how the fastest people do it. The top is finished in just two goes, but there are lots of moves to learn."
        }
    }

    /// The stages this method goes through, in order.
    var stages: [SolveStage.Kind] {
        switch self {
        case .beginner:
            return [.hold, .daisy, .whiteCross, .whiteCorners, .middleRow,
                    .yellowCross, .yellowFace, .lastCorners, .lastEdges]
        case .faster:
            return [.hold, .cross, .pairs, .topCross, .topFace, .topCorners, .topEdges]
        case .speedcuber:
            return [.hold, .cross, .pairs, .oll, .pll]
        }
    }

    /// The stages that get a number: everything but holding the cube.
    var numbered: [SolveStage.Kind] { stages.filter { $0 != .hold } }

    func solve(_ state: CubeState, whiteFace: Face = .D) throws -> SolvePlan {
        var plan: SolvePlan
        switch self {
        case .beginner:
            plan = try BeginnerSolver.solve(state, whiteFace: whiteFace)
        case .faster:
            plan = try PairsSolver.solve(state, lastLayerInOneLook: false, whiteFace: whiteFace)
        case .speedcuber:
            plan = try PairsSolver.solve(state, lastLayerInOneLook: true, whiteFace: whiteFace)
        }
        plan.method = self
        return plan
    }
}
