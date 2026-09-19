import Foundation

/// What a smart cube's move messages actually mean, found out rather than
/// assumed.
///
/// A GAN cube does not send "R". It sends a number for the face and a bit for
/// the direction, and which number means which face is a detail of firmware
/// that GAN have never published. The app used to carry a hand-written table
/// for it, ported from a reverse-engineering project, and if that table is
/// wrong for the cube in front of you there is nothing anywhere in the app that
/// can notice — the numbers arrive, the table renames them, and every turn is
/// read as the wrong face for ever.
///
/// Worse, a wrong table need not even be a *possible* way of labelling a cube.
/// The grip machinery can undo any of the twenty-four ways a cube can be held,
/// so a table that is merely turned round would come out in the wash. A table
/// that maps the top and bottom to two faces that are not opposite each other
/// cannot be undone by holding the cube differently, so no grip ever fits, and
/// the app spends the whole solve telling a child they turned the wrong side.
///
/// So nothing is assumed. The cube reports its own position as well as its
/// moves, and one turn either side of a position report says exactly what that
/// turn was — see ``Move/between(_:and:)``. The first time each label turns up,
/// the app asks the cube where it is and learns what the label meant; after
/// that it knows.
///
/// Measured in `Tools/CubeReference/dialect.py` over 300 solves, each against a
/// cube whose labels were shuffled at random and whose idea of clockwise was a
/// coin toss: 48,419 turns, not one read wrongly. Against a hard-coded table,
/// every single solve had turns read wrongly. A solve only ever turns five of
/// the six faces, so five questions is the whole cost.
struct SmartCubeDialect: Equatable, Sendable {

    /// What the cube's own word for a face turned out to mean, and whether its
    /// idea of clockwise agrees with ours.
    struct Meaning: Equatable, Sendable {
        var face: MoveBase
        var clockwiseIsReversed: Bool
    }

    private(set) var meanings: [Int: Meaning] = [:]

    /// Nothing known yet. Every label has to be asked about once.
    static let unknown = SmartCubeDialect()

    var isEmpty: Bool { meanings.isEmpty }

    func knows(_ label: Int) -> Bool { meanings[label] != nil }

    /// The move the child made, in the cube's own frame, or nil if this label
    /// has not been met yet and the cube has to be asked.
    func move(forLabel label: Int, clockwise: Bool) -> Move? {
        guard let meaning = meanings[label] else { return nil }
        let turned = meaning.clockwiseIsReversed ? !clockwise : clockwise
        return Move(meaning.face, turned ? .clockwise : .counterClockwise)
    }

    /// Write down what a label meant, having watched the cube move.
    ///
    /// A half turn is two quarter turns to these cubes, so `move` is always a
    /// quarter turn here; a half turn arriving would say nothing about
    /// direction and is left alone rather than guessed at.
    mutating func learn(label: Int, clockwise: Bool, was move: Move) {
        guard move.amount != .half, !move.base.isRotation else { return }
        meanings[label] = Meaning(face: move.base,
                                  clockwiseIsReversed: (move.amount == .clockwise) != clockwise)
    }

    /// Throw it away and start again — a different cube, or one that has been
    /// shown to be lying.
    mutating func forget() { meanings = [:] }
}
