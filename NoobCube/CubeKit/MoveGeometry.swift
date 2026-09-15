import Foundation

extension MoveAmount {
    /// Quarter turns, signed so that a counter-clockwise turn animates the short
    /// way round rather than three quarters of the way.
    var signedQuarterTurns: Int {
        switch self {
        case .clockwise: return 1
        case .half: return 2
        case .counterClockwise: return -1
        }
    }
}

extension Move {
    /// Whether a cubelet at `position` is carried by this move.
    func moves(cubeletAt position: Vec3) -> Bool {
        if let face = base.face {
            return Vec3.dot(position, face.normal) == 1
        }
        switch base {
        case .M: return position.x == 0
        case .E: return position.y == 0
        case .S: return position.z == 0
        default: return true          // a whole-cube rotation takes everything
        }
    }

    /// The axis the layer spins about, pointing so that a positive right-handed
    /// rotation looks anti-clockwise from outside.
    var turnAxis: Vec3 { base.axis }
}
