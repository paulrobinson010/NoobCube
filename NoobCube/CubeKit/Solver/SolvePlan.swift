import Foundation

/// One step of the beginner method: a goal to reach and the moves that reach it.
struct SolveStage: Identifiable, Hashable, Sendable {

    enum Kind: String, CaseIterable, Codable, Hashable, Sendable {
        case hold
        case daisy
        case whiteCross
        case whiteCorners
        case middleRow
        case yellowCross
        case yellowFace
        case lastCorners
        case lastEdges
    }

    let kind: Kind
    var moves: [Move]

    var id: Kind { kind }
    var isDone: Bool { moves.isEmpty }
    var moveCount: Int { moves.count }
}

extension SolveStage.Kind {

    /// Short title, written to be read aloud to a child.
    var title: String {
        switch self {
        case .hold:         return "Hold your cube"
        case .daisy:        return "Make a daisy"
        case .whiteCross:   return "Make the white cross"
        case .whiteCorners: return "Fill in the white corners"
        case .middleRow:    return "Finish the middle row"
        case .yellowCross:  return "Make the yellow cross"
        case .yellowFace:   return "Make the whole yellow face"
        case .lastCorners:  return "Send the corners home"
        case .lastEdges:    return "Send the last pieces home"
        }
    }

    /// One sentence explaining what the child is looking for.
    var explanation: String {
        switch self {
        case .hold:
            return "Turn your whole cube so the white side is at the bottom and yellow is on top."
        case .daisy:
            return "Put four white edges around the yellow middle, so it looks like a flower with white petals."
        case .whiteCross:
            return "Spin each petal until its side colour matches the middle underneath, then turn that side twice to drop it down."
        case .whiteCorners:
            return "Find a corner with white on it in the top layer, put it right above its home, then do the shuffle until it drops in."
        case .middleRow:
            return "Find a top edge with no yellow, line its colour up with the middle, then send it left or right."
        case .yellowCross:
            return "Make a yellow plus sign on the top. A dot becomes an L, an L becomes a line, a line becomes a cross."
        case .yellowFace:
            return "Keep doing the fish until the whole top is yellow."
        case .lastCorners:
            return "Move the top corners around until each one is in the right place."
        case .lastEdges:
            return "Slide the last edges around and the cube is finished."
        }
    }

    /// A two or three word name for the checklist.
    var shortName: String {
        switch self {
        case .hold:         return "Hold it"
        case .daisy:        return "Daisy"
        case .whiteCross:   return "White cross"
        case .whiteCorners: return "White bottom"
        case .middleRow:    return "Middle row"
        case .yellowCross:  return "Yellow cross"
        case .yellowFace:   return "Yellow face"
        case .lastCorners:  return "Corners home"
        case .lastEdges:    return "Finished!"
        }
    }

    /// Why this step exists, in words a child can hold on to.
    var why: String {
        switch self {
        case .hold:
            return "So that left and right mean the same thing to both of us."
        case .daisy:
            return "The daisy is the white cross upside down. It's easier to build up there where you can see it."
        case .whiteCross:
            return "Flipping each petal down gives you a white cross with the sides matching too."
        case .whiteCorners:
            return "Once the corners drop in, the whole white side is done and the bottom layer never moves again."
        case .middleRow:
            return "Two layers finished. From here on you only touch the top."
        case .yellowCross:
            return "Getting the yellow edges facing up is the first half of the last layer."
        case .yellowFace:
            return "Now the whole top is yellow, even though the sides are still muddled."
        case .lastCorners:
            return "The corners go to their proper homes, ready for the very last move."
        case .lastEdges:
            return "The last four pieces slide into place and the cube is done."
        }
    }

    /// The one algorithm this stage leans on, if it has one.
    var algorithm: (name: String, moves: String)? {
        switch self {
        case .whiteCorners: return ("the shuffle", "R U R' U'")
        case .middleRow:    return ("send it right", "U R U' R' U' F' U F")
        case .yellowCross:  return ("the cross move", "F R U R' U' F'")
        case .yellowFace:   return ("the fish", "R U R' U R U2 R'")
        case .lastCorners:  return ("the corner swap", "R B' R F2 R' B R F2 R2")
        case .lastEdges:    return ("the edge swap", "R U' R U R U R U' R' U' R2")
        default:            return nil
        }
    }

    /// Order the stages are worked through.
    var step: Int { (SolveStage.Kind.allCases.firstIndex(of: self) ?? 0) + 1 }

    static var totalSteps: Int { SolveStage.Kind.allCases.count }
}

/// A complete route from a scanned cube to a solved one.
struct SolvePlan: Sendable {
    let start: CubeState
    var stages: [SolveStage]

    var allMoves: [Move] { stages.flatMap(\.moves) }
    var moveCount: Int { allMoves.count }
    var isAlreadySolved: Bool { allMoves.isEmpty }

    /// The stage the child should be working on now: the first with moves left.
    var currentStage: SolveStage? { stages.first { !$0.isDone } }

    /// Stages already finished, for the progress display.
    var completedCount: Int {
        guard let current = currentStage else { return stages.count }
        return stages.firstIndex(where: { $0.kind == current.kind }) ?? stages.count
    }

    func stage(_ kind: SolveStage.Kind) -> SolveStage? {
        stages.first { $0.kind == kind }
    }

    /// The cube as it will look once `kind` is finished.
    func state(after kind: SolveStage.Kind) -> CubeState {
        var state = start
        for stage in stages {
            state = state.applying(stage.moves)
            if stage.kind == kind { break }
        }
        return state
    }
}
