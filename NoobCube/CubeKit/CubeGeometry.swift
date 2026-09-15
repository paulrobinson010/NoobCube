import Foundation

/// Derives the 54-facelet permutation of every move from cube geometry.
///
/// A sticker is a (cubie position, outward normal) pair. Turning a layer
/// rotates both, which is enough to say where every sticker lands. Deriving the
/// tables this way rather than transcribing them means they cannot be mistyped.
enum CubeGeometry {

    /// Every sticker on the cube as (position, outward normal).
    static let stickers: [(position: Vec3, normal: Vec3)] = {
        var result: [(position: Vec3, normal: Vec3)] = []
        for x in -1...1 {
            for y in -1...1 {
                for z in -1...1 {
                    let position = Vec3(x, y, z)
                    for face in Face.allCases where Vec3.dot(position, face.normal) == 1 {
                        result.append((position, face.normal))
                    }
                }
            }
        }
        return result
    }()

    /// Facelet index 0..<54 of the sticker at `position` pointing along `normal`.
    static func faceletIndex(position: Vec3, normal: Vec3) -> Int {
        guard let face = Face.face(withNormal: normal) else {
            preconditionFailure("\(normal) is not a face normal")
        }
        let row = 1 - Vec3.dot(position, face.imageUp)
        let col = 1 + Vec3.dot(position, face.imageRight)
        return face.rawValue * 9 + row * 3 + col
    }

    /// `permutation[i]` is the facelet that moves *into* slot `i`.
    private static func permutation(axis: Vec3, include: (Vec3) -> Bool) -> [Int] {
        var permutation = Array(0..<54)
        for (position, normal) in stickers where include(position) {
            let source = faceletIndex(position: position, normal: normal)
            let destination = faceletIndex(position: position.rotatedClockwise(about: axis),
                                           normal: normal.rotatedClockwise(about: axis))
            permutation[destination] = source
        }
        return permutation
    }

    /// Quarter-turn permutation for each base, computed once.
    static let quarterTurns: [MoveBase: [Int]] = {
        var table: [MoveBase: [Int]] = [:]
        for base in MoveBase.allCases {
            let axis = base.axis
            let include: (Vec3) -> Bool
            if let face = base.face {
                include = { Vec3.dot($0, face.normal) == 1 }
            } else if base.isSlice {
                // The slice is the layer the matching face turn does not touch.
                let perpendicular: Vec3
                switch base {
                case .M: perpendicular = Vec3(1, 0, 0)
                case .E: perpendicular = Vec3(0, 1, 0)
                default: perpendicular = Vec3(0, 0, 1)
                }
                include = { Vec3.dot($0, perpendicular) == 0 }
            } else {
                include = { _ in true }
            }
            table[base] = permutation(axis: axis, include: include)
        }
        return table
    }()

    /// Full permutation for a move, including its amount.
    static func permutation(for move: Move) -> [Int] {
        guard let quarter = quarterTurns[move.base] else {
            preconditionFailure("missing permutation for \(move.base)")
        }
        var result = quarter
        for _ in 1..<move.amount.rawValue {
            result = result.map { quarter[$0] }
        }
        return result
    }

    /// Cached full permutations for every move, so turning is a single lookup.
    static let allPermutations: [Move: [Int]] = {
        var table: [Move: [Int]] = [:]
        for base in MoveBase.allCases {
            for amount in MoveAmount.allCases {
                let move = Move(base, amount)
                table[move] = permutation(for: move)
            }
        }
        return table
    }()
}
