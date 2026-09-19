import Foundation

/// One piece being put where it belongs, and why.
///
/// A child can copy "F, then R, then U" all afternoon and learn nothing. What
/// makes it stick is knowing that *this* piece is going into *that* gap, that
/// you line it up first, and that the moves after the lining up are always the
/// same ones. So the plan is kept in those units and the app says what it is
/// about to do before it does it.
struct SolveStep: Identifiable, Hashable, Sendable {

    /// Getting something where you can work on it, or doing the move itself.
    /// They are different jobs and a child needs them kept apart.
    enum Purpose: String, Hashable, Sendable {
        /// Spinning the top, turning the whole cube, or freeing a piece.
        case positioning
        /// The moves that put the piece where it belongs.
        case move
    }

    var purpose: Purpose = .move

    /// The colours of the piece this is about, in solver space. Empty for the
    /// last-layer moves, which are about the whole top rather than one piece.
    var piece: [Face] = []

    /// Where that piece is now, and the gap it is going into.
    var from: [Int] = []
    var to: [Int] = []

    /// The one square to watch, and where these moves put it. Always a square
    /// that really moves: pointing at something that stays still while the
    /// cube changes around it teaches nothing.
    var marker: Int?
    var target: Int?

    var moves: [Move] = []
    var algorithmName: String?

    /// One sentence. Kept short enough to read at a glance, which is why
    /// positioning and the move are separate steps rather than one paragraph.
    var text: String?

    /// False for a step that only gets something out of the way.
    var places = false

    var index = 0
    var id: Int { index }

    var isEmpty: Bool { moves.isEmpty }
}

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

        /// How far through a solve this stage is. The cases are declared in the
        /// order they are done, so comparing these says whether a cube has gone
        /// forwards or backwards.
        var howFarThrough: Int { Self.allCases.firstIndex(of: self) ?? 0 }

        /// What a child would see come apart if a cube went back this far,
        /// said the way they would say it.
        var whatItTakesApart: String {
            switch self {
            case .hold, .daisy: return "daisy"
            case .whiteCross: return "white cross"
            case .whiteCorners: return "white side"
            case .middleRow: return "middle row"
            case .yellowCross: return "yellow cross"
            case .yellowFace: return "yellow top"
            case .lastCorners, .lastEdges: return "last layer"
            }
        }
    }

    let kind: Kind
    /// The pieces this stage puts right, in order.
    var steps: [SolveStep]

    /// Every move of the stage, which is simply its steps end to end.
    var moves: [Move] { steps.flatMap(\.moves) }

    var id: Kind { kind }
    var isDone: Bool { steps.allSatisfy(\.isEmpty) }
    var moveCount: Int { moves.count }

    /// The step that move number `index` belongs to, and where the step starts.
    func step(atMove index: Int) -> (step: SolveStep, start: Int)? {
        var start = 0
        for step in steps {
            let end = start + step.moves.count
            if index < end { return (step, start) }
            start = end
        }
        return nil
    }
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
            return "Find a corner with white on it in the top layer, put it above the gap whose three middles match its colours, then do righty until it drops in. If there's no white corner up top, one righty on a stuck one lifts it out so you can."
        case .middleRow:
            return "Find a top edge with no yellow, line its colour up with the middle, then send it left or right."
        case .yellowCross:
            return "Make a yellow plus sign on top. One move does it all: a dot becomes an L, an L becomes a line, a line becomes the cross. Turning the top first is how you point the shape the right way."
        case .yellowFace:
            return "The fish is one yellow corner with two yellow stickers beside it. Line it up at the front left and the fish move spins three corners at once — again and again until the top is all yellow."
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
            return "Getting the yellow edges facing up is the first half of the last layer. The move is always the same — lining the shape up is the thinking part."
        case .yellowFace:
            return "Now the whole top is yellow, even though the sides are still muddled. Only the corners moved, so the cross you just made is still there."
        case .lastCorners:
            return "The corners go to their proper homes. Going back to the fish breaks the yellow face on purpose, and doing the fish again brings it straight back with two corners swapped."
        case .lastEdges:
            return "The last four pieces slide into place and the cube is done."
        }
    }

    /// The one algorithm this stage leans on, if it has one.
    var algorithm: (name: String, moves: String)? {
        switch self {
        case .whiteCorners: return ("righty", "R U R' U'")
        case .middleRow:    return ("send it right", "U R U' R' U' F' U F")
        case .yellowCross:  return ("the cross move", "F U R U' R' F'")
        case .yellowFace:   return ("the fish", "R U R' U R U2 R'")
        case .lastCorners:  return ("back to the fish", "L' U R U' L U R'")
        case .lastEdges:    return ("the edge swap", "F2 U R' L F2 L' R U F2")
        default:            return nil
        }
    }

    /// Where this stage comes in the order of work. Not shown to anyone.
    var order: Int { (SolveStage.Kind.allCases.firstIndex(of: self) ?? 0) + 1 }

    /// The number the child sees on the checklist and hears spoken aloud.
    ///
    /// Holding the cube the right way up is how you start rather than a step
    /// you tick off, so it has no number, and the eight that follow are the
    /// eight the website lists. One number, everywhere.
    var number: Int? {
        SolveStage.Kind.numbered.firstIndex(of: self).map { $0 + 1 }
    }

    /// The stages that get a number, in order.
    static var numbered: [SolveStage.Kind] { allCases.filter { $0 != .hold } }

    static var totalNumbered: Int { numbered.count }
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
