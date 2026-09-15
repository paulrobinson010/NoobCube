import Foundation

/// An integer lattice vector. Cubie positions and face normals both live in
/// {-1, 0, 1}^3, so integer arithmetic keeps the geometry exact.
struct Vec3: Hashable, Sendable {
    var x: Int
    var y: Int
    var z: Int

    init(_ x: Int, _ y: Int, _ z: Int) {
        self.x = x
        self.y = y
        self.z = z
    }

    var negated: Vec3 { Vec3(-x, -y, -z) }

    /// Number of non-zero components: 1 for a centre, 2 for an edge, 3 for a corner.
    var rank: Int { (x == 0 ? 0 : 1) + (y == 0 ? 0 : 1) + (z == 0 ? 0 : 1) }

    static func dot(_ a: Vec3, _ b: Vec3) -> Int {
        a.x * b.x + a.y * b.y + a.z * b.z
    }

    static func cross(_ a: Vec3, _ b: Vec3) -> Vec3 {
        Vec3(a.y * b.z - a.z * b.y,
             a.z * b.x - a.x * b.z,
             a.x * b.y - a.y * b.x)
    }

    static func + (a: Vec3, b: Vec3) -> Vec3 {
        Vec3(a.x + b.x, a.y + b.y, a.z + b.z)
    }

    func scaled(by k: Int) -> Vec3 { Vec3(x * k, y * k, z * k) }

    /// A quarter turn clockwise as seen from outside, looking down `axis`.
    ///
    /// Clockwise-from-outside is -90 degrees in the right-hand sense, which
    /// Rodrigues' formula reduces to `-(axis x v) + axis * (axis . v)`.
    func rotatedClockwise(about axis: Vec3) -> Vec3 {
        Vec3.cross(axis, self).negated + axis.scaled(by: Vec3.dot(axis, self))
    }
}
