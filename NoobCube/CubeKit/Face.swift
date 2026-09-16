import Foundation

/// The six faces of the cube, in the order used for facelet indexing:
/// U(0...8) R(9...17) F(18...26) D(27...35) L(36...44) B(45...53).
enum Face: Int, CaseIterable, Codable, Hashable, Sendable {
    case U = 0, R, F, D, L, B

    var letter: String {
        switch self {
        case .U: return "U"
        case .R: return "R"
        case .F: return "F"
        case .D: return "D"
        case .L: return "L"
        case .B: return "B"
        }
    }

    init?(letter: Character) {
        switch letter {
        case "U": self = .U
        case "R": self = .R
        case "F": self = .F
        case "D": self = .D
        case "L": self = .L
        case "B": self = .B
        default: return nil
        }
    }

    var opposite: Face {
        switch self {
        case .U: return .D
        case .D: return .U
        case .R: return .L
        case .L: return .R
        case .F: return .B
        case .B: return .F
        }
    }

    /// Outward normal, in a right-handed frame with x right, y up, z towards the viewer.
    var normal: Vec3 {
        switch self {
        case .U: return Vec3(0, 1, 0)
        case .R: return Vec3(1, 0, 0)
        case .F: return Vec3(0, 0, 1)
        case .D: return Vec3(0, -1, 0)
        case .L: return Vec3(-1, 0, 0)
        case .B: return Vec3(0, 0, -1)
        }
    }

    /// Which way is "up" when this face is drawn flat, as in a standard cube net.
    /// U is drawn with the B edge at the top and D with the F edge at the top;
    /// the four side faces are drawn with U at the top.
    var imageUp: Vec3 {
        switch self {
        case .U: return Vec3(0, 0, -1)
        case .D: return Vec3(0, 0, 1)
        default: return Vec3(0, 1, 0)
        }
    }

    /// Which way is "right" when this face is drawn flat.
    var imageRight: Vec3 {
        // The viewer looks along -normal, so right = forward x up.
        Vec3.cross(normal.negated, imageUp)
    }

    /// Index of this face's centre facelet.
    var centreIndex: Int { rawValue * 9 + 4 }

    /// The nine facelet indices of this face, in reading order.
    var faceletIndices: Range<Int> { (rawValue * 9)..<(rawValue * 9 + 9) }

    static func face(withNormal normal: Vec3) -> Face? {
        Face.allCases.first { $0.normal == normal }
    }

    /// The face a facelet index belongs to. Indices run U, R, F, D, L, B, nine
    /// at a time, so this is simply which block of nine it falls in.
    static func of(facelet index: Int) -> Face {
        Face(rawValue: index / 9) ?? .U
    }
}
