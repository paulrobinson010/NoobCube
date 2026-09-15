import Foundation

/// How the colours sit on a standard cube.
///
/// White is opposite yellow, red opposite orange, blue opposite green — and the
/// handedness is fixed too: hold a cube with white up and green towards you and
/// red is always on the right. That is enough to work out where every face is
/// from the centres alone, which is why the app never needs to see two sides at
/// once to know how the cube is being held.
enum CubeColourScheme {

    /// The reference way of holding a cube: white up, green front, red right.
    static let reference: [Face: CubeColour] = [
        .U: .white, .D: .yellow,
        .F: .green, .B: .blue,
        .R: .red,   .L: .orange,
    ]

    /// All 24 ways a standard cube can be held.
    static let orientations: [[Face: CubeColour]] = {
        var found: [[CubeColour]: [Face: CubeColour]] = [:]
        var frontier = [reference]
        found[key(reference)] = reference

        let turns = [Move(.x), Move(.y), Move(.z)]
        while let layout = frontier.popLast() {
            for move in turns {
                let next = rotated(layout, by: move)
                if found[key(next)] == nil {
                    found[key(next)] = next
                    frontier.append(next)
                }
            }
        }
        return Array(found.values)
    }()

    private static func key(_ layout: [Face: CubeColour]) -> [CubeColour] {
        Face.allCases.map { layout[$0] ?? .white }
    }

    /// Turn a whole cube and read the centres back.
    private static func rotated(_ layout: [Face: CubeColour], by move: Move) -> [Face: CubeColour] {
        var colours = [CubeColour?](repeating: nil, count: 54)
        for face in Face.allCases {
            for index in face.faceletIndices {
                colours[index] = layout[face]
            }
        }
        let turned = ScannedCube(colours: colours).applying(move)
        var result: [Face: CubeColour] = [:]
        for face in Face.allCases {
            result[face] = turned[face.centreIndex]
        }
        return result
    }

    /// The way of holding the cube that puts `top` up and `front` at the front.
    static func orientation(top: CubeColour, front: CubeColour) -> [Face: CubeColour]? {
        orientations.first { $0[.U] == top && $0[.F] == front }
    }

    /// How the app lays a cube out while scanning and solving: yellow on top,
    /// white underneath, green at the front. The child is asked to hold it this
    /// way, and the flat net is drawn to match.
    static let scanningLayout: [Face: CubeColour] = orientation(top: .yellow, front: .green)
        ?? reference

    /// Which face a side belongs on, going by the colour of its middle sticker.
    static func face(forCentre colour: CubeColour,
                     in layout: [Face: CubeColour] = scanningLayout) -> Face? {
        Face.allCases.first { layout[$0] == colour }
    }

    /// Is this a set of centres a real cube could have?
    static func isPlausible(centres: [Face: CubeColour]) -> Bool {
        orientations.contains { candidate in
            Face.allCases.allSatisfy { centres[$0] == nil || centres[$0] == candidate[$0] }
        }
    }
}
