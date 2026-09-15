import Foundation

/// A place on the cube that holds one edge or corner piece.
///
/// `faces` and `indices` share a canonical order chosen so that the standard
/// solvability invariants hold: the U or D sticker comes first, and for corners
/// the remaining two follow clockwise as seen from outside the cube.
struct CubeSlot: Hashable, Sendable {
    let name: String
    let faces: [Face]
    let indices: [Int]
    let position: Vec3

    var isEdge: Bool { faces.count == 2 }
    var isCorner: Bool { faces.count == 3 }

    /// The faces of this slot that are not U or D.
    var sideFaces: [Face] { faces.filter { $0 != .U && $0 != .D } }

    func contains(_ face: Face) -> Bool { faces.contains(face) }

    /// The colour of this slot's sticker that sits on `face`.
    func sticker(on face: Face, in state: CubeState) -> Face? {
        guard let position = faces.firstIndex(of: face) else { return nil }
        return state[indices[position]]
    }

    /// The face of this slot whose sticker currently shows `colour`.
    func face(showing colour: Face, in state: CubeState) -> Face? {
        guard let position = indices.firstIndex(where: { state[$0] == colour }) else { return nil }
        return faces[position]
    }

    /// The colours currently sitting in this slot, in canonical order.
    func colours(in state: CubeState) -> [Face] { indices.map { state[$0] } }

    /// The piece currently here, identified by its set of colours.
    func piece(in state: CubeState) -> Set<Face> { Set(colours(in: state)) }

    /// True when the right piece is here the right way round.
    func isSolved(in state: CubeState) -> Bool {
        zip(faces, indices).allSatisfy { state[$0.1] == $0.0 }
    }

    /// True when the right piece is here, however it is turned.
    func holdsHomePiece(in state: CubeState) -> Bool {
        piece(in: state) == Set(faces)
    }

    /// Edge flip (0 or 1) or corner twist (0, 1 or 2); nil if the piece is impossible.
    func orientation(in state: CubeState) -> Int? {
        let colours = colours(in: state)
        if isEdge {
            guard let leading = CubeSlots.leadingEdgeColour(colours) else { return nil }
            return colours[0] == leading ? 0 : 1
        }
        return colours.firstIndex { $0 == .U || $0 == .D }
    }
}

enum CubeSlots {

    /// The sticker that comes first in canonical order: U or D if the piece has
    /// one, otherwise F or B.
    static func leadingEdgeColour(_ colours: [Face]) -> Face? {
        colours.first { $0 == .U || $0 == .D } ?? colours.first { $0 == .F || $0 == .B }
    }

    private static func buildSlots(rank: Int) -> [CubeSlot] {
        var slots: [CubeSlot] = []
        for x in -1...1 {
            for y in -1...1 {
                for z in -1...1 {
                    let position = Vec3(x, y, z)
                    guard position.rank == rank else { continue }
                    let faces = Face.allCases.filter { Vec3.dot(position, $0.normal) == 1 }
                    let ordered = canonicalOrder(faces: faces, position: position)
                    let indices = ordered.map {
                        CubeGeometry.faceletIndex(position: position, normal: $0.normal)
                    }
                    slots.append(CubeSlot(name: ordered.map(\.letter).joined(),
                                          faces: ordered,
                                          indices: indices,
                                          position: position))
                }
            }
        }
        return slots
    }

    /// U or D sticker first; for corners the other two then follow clockwise
    /// as seen from outside, which is what makes the twists sum to 0 mod 3.
    private static func canonicalOrder(faces: [Face], position: Vec3) -> [Face] {
        let leading = faces.first { $0 == .U || $0 == .D }
            ?? faces.first { $0 == .F || $0 == .B }
            ?? faces[0]
        let rest = faces.filter { $0 != leading }
        guard rest.count == 2 else { return [leading] + rest }
        // Going leading -> a is clockwise from outside when (leading x a) points inwards.
        let a = rest[0]
        let clockwise = Vec3.dot(Vec3.cross(leading.normal, a.normal), position) < 0
        return clockwise ? [leading, rest[0], rest[1]] : [leading, rest[1], rest[0]]
    }

    static let edges: [CubeSlot] = buildSlots(rank: 2)
    static let corners: [CubeSlot] = buildSlots(rank: 3)
    static let all: [CubeSlot] = edges + corners

    static func slot(named name: String) -> CubeSlot? {
        all.first { $0.name == name }
    }

    /// Look a slot up by the faces it spans, without depending on name order.
    static func slot(with faces: Set<Face>) -> CubeSlot? {
        all.first { Set($0.faces) == faces }
    }

    static let topEdges: [CubeSlot] = edges.filter { $0.contains(.U) }
    static let bottomEdges: [CubeSlot] = edges.filter { $0.contains(.D) }
    static let middleEdges: [CubeSlot] = edges.filter { !$0.contains(.U) && !$0.contains(.D) }
    static let topCorners: [CubeSlot] = corners.filter { $0.contains(.U) }
    static let bottomCorners: [CubeSlot] = corners.filter { $0.contains(.D) }

    /// Where a given piece currently is.
    static func slot(holding piece: Set<Face>, in state: CubeState) -> CubeSlot? {
        let group = piece.count == 2 ? edges : corners
        return group.first { $0.piece(in: state) == piece }
    }

    /// Parity of the permutation taking slots to the pieces in them.
    /// Returns nil if some piece appears twice, which means the scan is wrong.
    static func permutationParity(of group: [CubeSlot], in state: CubeState) -> Int? {
        var destination: [String: String] = [:]
        var homes: [Set<Face>: String] = [:]
        for slot in group {
            homes[Set(slot.faces)] = slot.name
        }
        for slot in group {
            guard let home = homes[slot.piece(in: state)] else { return nil }
            destination[slot.name] = home
        }
        guard Set(destination.values).count == group.count else { return nil }

        var seen: Set<String> = []
        var parity = 0
        for slot in group where !seen.contains(slot.name) {
            var length = 0
            var current = slot.name
            while !seen.contains(current) {
                seen.insert(current)
                guard let next = destination[current] else { return nil }
                current = next
                length += 1
            }
            parity += length - 1
        }
        return parity % 2
    }
}
