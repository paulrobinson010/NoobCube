import Foundation

/// Turning a move into something you can say to a five year old.
///
/// The directions here were checked against the move engine rather than
/// guessed: an R turn really does carry the front face up, a U turn really does
/// carry the front face to the left, and so on.
extension Move {

    /// A short label for the move strip, e.g. "Right up".
    var childLabel: String {
        switch base {
        case .R: return amount == .half ? "Right up x2" : (isPrime ? "Right down" : "Right up")
        case .L: return amount == .half ? "Left down x2" : (isPrime ? "Left up" : "Left down")
        case .U: return amount == .half ? "Top across" : (isPrime ? "Top right" : "Top left")
        case .D: return amount == .half ? "Bottom across" : (isPrime ? "Bottom left" : "Bottom right")
        case .F: return amount == .half ? "Front around" : (isPrime ? "Front left" : "Front right")
        case .B: return amount == .half ? "Back around" : (isPrime ? "Back right" : "Back left")
        case .x, .y, .z: return "Turn the cube"
        case .M, .E, .S: return "Middle slice"
        }
    }

    /// The full sentence the app says out loud.
    var spokenInstruction: String {
        let twice = amount == .half ? ", twice" : ""
        switch base {
        case .R:
            return isPrime ? "Turn the right side down\(twice)." : "Turn the right side up\(twice)."
        case .L:
            return isPrime ? "Turn the left side up\(twice)." : "Turn the left side down\(twice)."
        case .U:
            return isPrime ? "Turn the top row to the right\(twice)." : "Turn the top row to the left\(twice)."
        case .D:
            return isPrime ? "Turn the bottom row to the left\(twice)." : "Turn the bottom row to the right\(twice)."
        case .F:
            return isPrime ? "Turn the front face to the left\(twice)." : "Turn the front face to the right\(twice)."
        case .B:
            return isPrime ? "Turn the back face to the right\(twice)." : "Turn the back face to the left\(twice)."
        case .y:
            if amount == .half { return "Spin the whole cube around to face the back." }
            return isPrime ? "Spin the whole cube to the right." : "Spin the whole cube to the left."
        case .x:
            if amount == .half { return "Turn the whole cube upside down." }
            return isPrime ? "Tip the whole cube forwards, so the top comes to the front."
                           : "Tip the whole cube back, so the front goes on top."
        case .z:
            if amount == .half { return "Roll the whole cube over sideways." }
            return isPrime ? "Tip the whole cube to the left." : "Tip the whole cube to the right."
        case .M, .E, .S:
            return "Turn the middle slice."
        }
    }

    /// Whole-cube turns are a re-grip, not a move, and are shown differently.
    var isWholeCubeTurn: Bool { base.isRotation }

    private var isPrime: Bool { amount == .counterClockwise }
}

extension Array where Element == Move {
    /// "Right side up, then top row to the left, then ..." for reading a whole
    /// stage aloud when the child wants to hear it in one go.
    var spokenSequence: String {
        guard !isEmpty else { return "Nothing to do here." }
        return map(\.spokenInstruction).joined(separator: " ")
    }
}

extension String {
    /// The same words with a capital letter at the front, for a label that
    /// starts a line rather than sitting inside a sentence.
    var sentenceCased: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
