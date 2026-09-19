import Foundation

/// The layer or axis a move turns.
enum MoveBase: String, CaseIterable, Codable, Hashable, Sendable {
    case U, R, F, D, L, B          // face turns
    case M, E, S                   // slice turns
    case x, y, z                   // whole-cube rotations

    var isFaceTurn: Bool {
        switch self {
        case .U, .R, .F, .D, .L, .B: return true
        default: return false
        }
    }

    var isRotation: Bool {
        switch self {
        case .x, .y, .z: return true
        default: return false
        }
    }

    var isSlice: Bool {
        switch self {
        case .M, .E, .S: return true
        default: return false
        }
    }

    /// The face this base turns, for face turns.
    var face: Face? {
        switch self {
        case .U: return .U
        case .R: return .R
        case .F: return .F
        case .D: return .D
        case .L: return .L
        case .B: return .B
        default: return nil
        }
    }

    /// The axis the layer spins about, and the direction that counts as clockwise.
    var axis: Vec3 {
        switch self {
        case .U: return Face.U.normal
        case .R: return Face.R.normal
        case .F: return Face.F.normal
        case .D: return Face.D.normal
        case .L: return Face.L.normal
        case .B: return Face.B.normal
        case .M: return Face.L.normal      // M follows L
        case .E: return Face.D.normal      // E follows D
        case .S: return Face.F.normal      // S follows F
        case .x: return Face.R.normal
        case .y: return Face.U.normal
        case .z: return Face.F.normal
        }
    }
}

extension MoveBase {
    /// The face turn for a given face.
    init(_ face: Face) {
        switch face {
        case .U: self = .U
        case .R: self = .R
        case .F: self = .F
        case .D: self = .D
        case .L: self = .L
        case .B: self = .B
        }
    }
}

/// How far a move turns.
enum MoveAmount: Int, CaseIterable, Codable, Hashable, Sendable {
    case clockwise = 1
    case half = 2
    case counterClockwise = 3

    var suffix: String {
        switch self {
        case .clockwise: return ""
        case .half: return "2"
        case .counterClockwise: return "'"
        }
    }

    var inverse: MoveAmount {
        switch self {
        case .clockwise: return .counterClockwise
        case .half: return .half
        case .counterClockwise: return .clockwise
        }
    }

    /// Turn angle in radians, positive being clockwise seen from outside.
    var radians: Double {
        Double(rawValue) * .pi / 2
    }
}

struct Move: Hashable, Codable, Sendable {
    var base: MoveBase
    var amount: MoveAmount

    init(_ base: MoveBase, _ amount: MoveAmount = .clockwise) {
        self.base = base
        self.amount = amount
    }

    var notation: String { base.rawValue + amount.suffix }

    var inverse: Move { Move(base, amount.inverse) }

    /// Every turn of a single face: six faces, three amounts each.
    static let everyFaceTurn: [Move] = MoveBase.allCases
        .filter { !$0.isRotation }
        .flatMap { base in
            [MoveAmount.clockwise, .half, .counterClockwise].map { Move(base, $0) }
        }

    /// Which single turn took the cube from one position to the other.
    ///
    /// There is never more than one answer. A face turn moves twenty stickers
    /// and no two of the eighteen possible turns move them the same way, so
    /// looking for the one that fits is not a guess — it is arithmetic.
    /// Checked over 57,906 turns along 400 real solves in
    /// `Tools/CubeReference/dialect.py`: never wrong, never two answers.
    ///
    /// This is what lets the app stop believing a hand-written table about
    /// what a smart cube calls its own faces, and find out instead.
    static func between(_ before: CubeState, and after: CubeState) -> Move? {
        var found: Move?
        for candidate in everyFaceTurn where before.applying(candidate) == after {
            guard found == nil else { return nil }
            found = candidate
        }
        return found
    }

    var isRotation: Bool { base.isRotation }

    init?(notation: String) {
        let trimmed = notation.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first,
              let base = MoveBase(rawValue: String(first)) else { return nil }
        let rest = String(trimmed.dropFirst())
        switch rest {
        case "": self.init(base, .clockwise)
        case "2": self.init(base, .half)
        case "'", "’": self.init(base, .counterClockwise)
        default: return nil
        }
    }

    /// Parse a space-separated sequence such as `"R U R' U'"`.
    static func parse(_ sequence: String) -> [Move] {
        sequence.split(whereSeparator: { $0 == " " || $0 == "\n" })
            .compactMap { Move(notation: String($0)) }
    }

    static func notation(for moves: [Move]) -> String {
        moves.map(\.notation).joined(separator: " ")
    }

    static func invert(_ moves: [Move]) -> [Move] {
        moves.reversed().map(\.inverse)
    }
}
