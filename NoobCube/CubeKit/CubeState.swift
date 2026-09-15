import Foundation

/// The colour of all 54 stickers, each named by the face it belongs on when solved.
///
/// The cube is stored in "face letter" space rather than in real colours: a
/// facelet holds `.F` when it carries whatever colour the F centre carries. That
/// keeps the solver independent of the cube's colour scheme, and lets a solved
/// cube always compare equal to ``CubeState/solved``.
struct CubeState: Equatable, Hashable, Codable, Sendable {

    /// 54 entries, indexed U(0...8) R(9...17) F(18...26) D(27...35) L(36...44) B(45...53).
    private(set) var facelets: [Face]

    init(facelets: [Face]) {
        precondition(facelets.count == 54, "a cube has 54 facelets, got \(facelets.count)")
        self.facelets = facelets
    }

    static let solved = CubeState(facelets: Face.allCases.flatMap { Array(repeating: $0, count: 9) })

    var isSolved: Bool { self == .solved }

    subscript(index: Int) -> Face { facelets[index] }

    /// The colour letters as a 54 character string, e.g. for logging or tests.
    var notation: String { facelets.map(\.letter).joined() }

    init?(notation: String) {
        let faces = notation.compactMap { Face(letter: $0) }
        guard faces.count == 54 else { return nil }
        self.init(facelets: faces)
    }

    // MARK: - Turning

    /// Apply a single move.
    ///
    /// A whole-cube rotation also re-labels the colours, so that a solved cube
    /// stays solved after it. That mirrors what a person does when they re-grip:
    /// the stickers move, but "the front face" still means whatever is now in
    /// front. Without it, every position test after a rotation would be wrong.
    func applying(_ move: Move) -> CubeState {
        guard let permutation = CubeGeometry.allPermutations[move] else { return self }
        var turned = [Face](repeating: .U, count: 54)
        for index in 0..<54 {
            turned[index] = facelets[permutation[index]]
        }
        let result = CubeState(facelets: turned)
        return move.isRotation ? result.relabelled() : result
    }

    func applying(_ moves: [Move]) -> CubeState {
        moves.reduce(self) { $0.applying($1) }
    }

    func applying(_ sequence: String) -> CubeState {
        applying(Move.parse(sequence))
    }

    /// Rename colours so that every centre reads as its own face again.
    func relabelled() -> CubeState {
        var rename: [Face: Face] = [:]
        for face in Face.allCases {
            rename[facelets[face.centreIndex]] = face
        }
        return CubeState(facelets: facelets.map { rename[$0] ?? $0 })
    }

    // MARK: - Validation

    enum Problem: Equatable, Sendable {
        case wrongStickerCount(Face, Int)
        case duplicateCentre
        case badPiece(String)
        case unsolvable(String)

        var message: String {
            switch self {
            case .wrongStickerCount(let face, let count):
                return "There are \(count) \(face.letter) stickers, but there should be 9."
            case .duplicateCentre:
                return "Two centres have the same colour."
            case .badPiece(let detail):
                return detail
            case .unsolvable(let detail):
                return detail
            }
        }
    }

    /// Checks the scan produced a cube that can actually exist.
    ///
    /// Catches the mistakes a camera scan really makes — a misread sticker
    /// giving ten of one colour, or two stickers of the same colour on one
    /// piece — before the solver is handed something impossible.
    func validate() -> [Problem] {
        var problems: [Problem] = []

        for face in Face.allCases {
            let count = facelets.filter { $0 == face }.count
            if count != 9 {
                problems.append(.wrongStickerCount(face, count))
            }
        }
        let centres = Set(Face.allCases.map { facelets[$0.centreIndex] })
        if centres.count != 6 {
            problems.append(.duplicateCentre)
        }
        guard problems.isEmpty else { return problems }

        for slot in CubeSlots.edges {
            let colours = Set(slot.indices.map { facelets[$0] })
            if colours.count != 2 {
                problems.append(.badPiece("The \(slot.name) edge has two stickers the same colour."))
            } else if let a = colours.first, colours.contains(a.opposite) {
                problems.append(.badPiece("The \(slot.name) edge has two opposite colours on it."))
            }
        }
        for slot in CubeSlots.corners {
            let colours = Set(slot.indices.map { facelets[$0] })
            if colours.count != 3 {
                problems.append(.badPiece("The \(slot.name) corner has two stickers the same colour."))
            }
        }
        guard problems.isEmpty else { return problems }

        if let parity = parityProblem() {
            problems.append(parity)
        }
        return problems
    }

    var isValid: Bool { validate().isEmpty }

    /// The three classic solvability invariants: edge flips are even, corner
    /// twists cancel out mod 3, and the two piece permutations share parity.
    private func parityProblem() -> Problem? {
        var edgeFlip = 0
        for slot in CubeSlots.edges {
            guard let orientation = slot.orientation(in: self) else {
                return .badPiece("The \(slot.name) edge is not a real edge piece.")
            }
            edgeFlip += orientation
        }
        if edgeFlip % 2 != 0 {
            return .unsolvable("One edge is flipped the wrong way round — check the scan.")
        }

        var cornerTwist = 0
        for slot in CubeSlots.corners {
            guard let orientation = slot.orientation(in: self) else {
                return .badPiece("The \(slot.name) corner is not a real corner piece.")
            }
            cornerTwist += orientation
        }
        if cornerTwist % 3 != 0 {
            return .unsolvable("One corner is twisted the wrong way round — check the scan.")
        }

        guard let edgePermutation = CubeSlots.permutationParity(of: CubeSlots.edges, in: self),
              let cornerPermutation = CubeSlots.permutationParity(of: CubeSlots.corners, in: self)
        else {
            return .unsolvable("Two pieces on the cube are the same — check the scan.")
        }
        if edgePermutation != cornerPermutation {
            return .unsolvable("Two pieces need swapping — check the scan.")
        }
        return nil
    }
}
