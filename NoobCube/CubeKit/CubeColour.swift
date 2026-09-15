import Foundation

/// A sticker colour on a real cube.
///
/// The solver works in face letters, not colours, so this only matters at the
/// two edges of the app: reading a cube in, and drawing one out.
enum CubeColour: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case white, yellow, green, blue, red, orange

    var id: String { rawValue }

    /// What the app calls this colour out loud.
    var spokenName: String { rawValue }

    var displayName: String { rawValue.capitalized }

    /// Roughly where this sticker sits in sRGB, used for drawing and as the
    /// starting point for classifying a camera sample.
    var rgb: (red: Double, green: Double, blue: Double) {
        switch self {
        case .white:  return (0.96, 0.96, 0.94)
        case .yellow: return (1.00, 0.84, 0.10)
        case .green:  return (0.11, 0.70, 0.35)
        case .blue:   return (0.05, 0.42, 0.85)
        case .red:    return (0.88, 0.16, 0.18)
        case .orange: return (0.98, 0.49, 0.09)
        }
    }

    /// The colour a sticker of this colour is usually opposite, on a cube using
    /// the standard scheme. Only used to sanity check a scan, never to solve.
    var conventionalOpposite: CubeColour {
        switch self {
        case .white:  return .yellow
        case .yellow: return .white
        case .green:  return .blue
        case .blue:   return .green
        case .red:    return .orange
        case .orange: return .red
        }
    }
}

/// A cube read in from the camera or a smart cube: 54 sticker colours, some of
/// which may not be known yet.
struct ScannedCube: Equatable, Codable, Sendable {

    /// Indexed the same way as ``CubeState``: U, R, F, D, L, B.
    private(set) var colours: [CubeColour?]

    init() {
        colours = Array(repeating: nil, count: 54)
    }

    init(colours: [CubeColour?]) {
        precondition(colours.count == 54)
        self.colours = colours
    }

    subscript(index: Int) -> CubeColour? {
        get { colours[index] }
        set { colours[index] = newValue }
    }

    /// Record all nine stickers of one face.
    mutating func setFace(_ face: Face, to stickers: [CubeColour]) {
        precondition(stickers.count == 9)
        for offset in 0..<9 {
            colours[face.rawValue * 9 + offset] = stickers[offset]
        }
    }

    mutating func clearFace(_ face: Face) {
        for offset in 0..<9 {
            colours[face.rawValue * 9 + offset] = nil
        }
    }

    func isFaceScanned(_ face: Face) -> Bool {
        face.faceletIndices.allSatisfy { colours[$0] != nil }
    }

    var scannedFaces: [Face] { Face.allCases.filter { isFaceScanned($0) } }

    var isComplete: Bool { colours.allSatisfy { $0 != nil } }

    var centres: [Face: CubeColour] {
        var result: [Face: CubeColour] = [:]
        for face in Face.allCases {
            if let colour = colours[face.centreIndex] {
                result[face] = colour
            }
        }
        return result
    }

    /// The face whose centre carries `colour`, once it has been seen.
    func face(withCentre colour: CubeColour) -> Face? {
        Face.allCases.first { colours[$0.centreIndex] == colour }
    }

    /// Turn one face's nine stickers a quarter turn at a time, in place.
    ///
    /// Used when the top or bottom was shown to the camera at an angle.
    mutating func rotateFaceStickers(_ face: Face, quarterTurns: Int) {
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns > 0 else { return }
        var grid = (0..<9).map { colours[face.rawValue * 9 + $0] }
        for _ in 0..<turns {
            // Clockwise: the new (row, column) comes from (2 - column, row).
            var turned = [CubeColour?](repeating: nil, count: 9)
            for row in 0..<3 {
                for column in 0..<3 {
                    turned[row * 3 + column] = grid[(2 - column) * 3 + row]
                }
            }
            grid = turned
        }
        for offset in 0..<9 {
            colours[face.rawValue * 9 + offset] = grid[offset]
        }
    }

    /// Move the stickers without renaming any colours.
    ///
    /// ``CubeState`` re-labels colours after a whole-cube rotation so that a
    /// solved cube still reads as solved. That is right for solving and wrong
    /// for drawing, where what matters is which colour is physically where. So
    /// the picture of the cube is turned with the raw permutation instead.
    func applying(_ move: Move) -> ScannedCube {
        guard let permutation = CubeGeometry.allPermutations[move] else { return self }
        var moved = [CubeColour?](repeating: nil, count: 54)
        for index in 0..<54 {
            moved[index] = colours[permutation[index]]
        }
        return ScannedCube(colours: moved)
    }

    func applying(_ moves: [Move]) -> ScannedCube {
        moves.reduce(self) { $0.applying($1) }
    }

    enum ConversionError: Error, LocalizedError {
        case incomplete
        case repeatedCentre

        var errorDescription: String? {
            switch self {
            case .incomplete:
                return "Some stickers haven't been seen yet."
            case .repeatedCentre:
                return "Two middle stickers are the same colour — let's look again."
            }
        }
    }

    /// Translate colours into the face-letter space the solver works in.
    ///
    /// The centres define the mapping, so this works whatever colour scheme the
    /// cube uses, and whichever way up it was scanned.
    func cubeState() throws -> (state: CubeState, whiteFace: Face) {
        guard isComplete else { throw ConversionError.incomplete }

        var faceForColour: [CubeColour: Face] = [:]
        for face in Face.allCases {
            guard let colour = colours[face.centreIndex] else { throw ConversionError.incomplete }
            guard faceForColour[colour] == nil else { throw ConversionError.repeatedCentre }
            faceForColour[colour] = face
        }

        var facelets: [Face] = []
        facelets.reserveCapacity(54)
        for index in 0..<54 {
            guard let colour = colours[index], let face = faceForColour[colour] else {
                throw ConversionError.incomplete
            }
            facelets.append(face)
        }
        let whiteFace = faceForColour[.white] ?? .D
        return (CubeState(facelets: facelets), whiteFace)
    }

    /// Render a solved-space cube back into colours, so the 3D view and the net
    /// can draw any position the solver passes through.
    static func colours(for state: CubeState, matching scan: ScannedCube) -> [CubeColour] {
        var colourForFace: [Face: CubeColour] = [:]
        for face in Face.allCases {
            colourForFace[face] = scan.colours[face.centreIndex] ?? CubeColour.defaultColour(for: face)
        }
        return state.facelets.map { colourForFace[$0] ?? .white }
    }
}

extension CubeColour {
    /// The usual colour for a face when nothing has been scanned yet: white on
    /// the bottom, yellow on top, green at the front.
    static func defaultColour(for face: Face) -> CubeColour {
        switch face {
        case .U: return .yellow
        case .D: return .white
        case .F: return .green
        case .B: return .blue
        case .R: return .orange
        case .L: return .red
        }
    }
}
