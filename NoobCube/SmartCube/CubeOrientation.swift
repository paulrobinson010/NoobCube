import Foundation

/// Which way up the cube is, from its own motion sensor.
///
/// A smart cube's face numbers are welded to the plastic, so the *state* it
/// reports is right however the child holds it — see ``SmartCubeManager``.
/// What it cannot say on its own is which of those faces is currently facing
/// the ceiling, and that is the only thing the grip was ever for: saying "turn
/// the right-hand side" means knowing which side is on their right.
///
/// The cube has a motion sensor and streams its orientation as a quaternion.
/// That answers the question outright, however the cube is turned or held, and
/// keeps answering it — a child spinning the cube round in their hands is
/// tracked exactly rather than guessed at from their next few turns.
///
/// **GAN's axes never have to be known.** The quaternion is in whatever frame
/// the cube's firmware chose, and the grip is in the child's; the two differ by
/// one fixed rotation. One moment where the grip is known independently — from
/// a scan, or from the turns settling it — pins that rotation, and it cancels
/// from then on. So a guess about which axis is which cannot be made, and
/// cannot be wrong.
///
/// Checked in `Tools/CubeReference/orientation.py`. Snapping a rotation to the
/// nearest of the twenty-four is exact up to a 44° tilt and only fails past 45°,
/// which is the halfway point between two ways of holding a cube and so the
/// most that is possible. Over 10,000 readings after a single calibration, with
/// the frame offset drawn at random each time:
///
///     cube held within  10°   100.0% read right
///                       20°   100.0%
///                       30°    99.6%
///                       35°    97.3%
///
/// A child holds a cube squarer than that, and the tolerance is the same at
/// calibration time as afterwards.
struct CubeOrientation: Equatable, Sendable {

    /// A rotation, as the cube's sensor sends it.
    struct Quaternion: Equatable, Sendable {
        var w, x, y, z: Double

        var isUsable: Bool {
            let size = w * w + x * x + y * y + z * z
            return size > 0.25 && size < 4 && size.isFinite
        }
    }

    /// A rotation as three rows, which is all this needs it for.
    struct Rotation: Equatable, Sendable {
        var rows: [[Double]]

        static let identity = Rotation(rows: [[1, 0, 0], [0, 1, 0], [0, 0, 1]])

        init(rows: [[Double]]) { self.rows = rows }

        init(_ q: Quaternion) {
            let size = (q.w * q.w + q.x * q.x + q.y * q.y + q.z * q.z).squareRoot()
            let n = size > 0.000001 ? size : 1
            let (w, x, y, z) = (q.w / n, q.x / n, q.y / n, q.z / n)
            rows = [
                [1 - 2 * (y * y + z * z), 2 * (x * y - z * w),     2 * (x * z + y * w)],
                [2 * (x * y + z * w),     1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
                [2 * (x * z - y * w),     2 * (y * z + x * w),     1 - 2 * (x * x + y * y)],
            ]
        }

        func times(_ other: Rotation) -> Rotation {
            var out = [[Double]](repeating: [0, 0, 0], count: 3)
            for i in 0..<3 {
                for j in 0..<3 {
                    out[i][j] = (0..<3).reduce(0) { $0 + rows[i][$1] * other.rows[$1][j] }
                }
            }
            return Rotation(rows: out)
        }

        /// A rotation's inverse is its transpose, which is why none of this
        /// needs anything cleverer than arithmetic.
        var inverse: Rotation {
            Rotation(rows: (0..<3).map { i in (0..<3).map { j in rows[j][i] } })
        }

        /// How nearly two rotations are the same thing.
        func agreement(with other: Rotation) -> Double {
            var total = 0.0
            for i in 0..<3 {
                for j in 0..<3 { total += rows[i][j] * other.rows[i][j] }
            }
            return total
        }
    }

    // MARK: - Grips as rotations

    /// The rotation a way of holding the cube performs, read off where it sends
    /// each face: a grip takes the cube's own frame to the child's, and the six
    /// face normals are the six signed axes, so each column falls straight out.
    static func rotation(of alignment: CubeAlignment) -> Rotation {
        var rows = [[Double]](repeating: [0, 0, 0], count: 3)
        for (cubeFace, appFace) in alignment.appFace {
            let from = cubeFace.normal, to = appFace.normal
            let column = from.x == 1 ? 0 : (from.y == 1 ? 1 : (from.z == 1 ? 2 : -1))
            guard column >= 0 else { continue }          // the negative axes repeat it
            rows[0][column] = Double(to.x)
            rows[1][column] = Double(to.y)
            rows[2][column] = Double(to.z)
        }
        return Rotation(rows: rows)
    }

    /// Every way of holding the cube, with the rotation each one is.
    static let everyGrip: [(alignment: CubeAlignment, rotation: Rotation)] = {
        CubeAlignment.allGrips.map { grip in
            let alignment = CubeAlignment.identity.regripped(by: grip)
            return (alignment, rotation(of: alignment))
        }
    }()

    /// The way of holding the cube this rotation is nearest to.
    ///
    /// Exact up to a 44° tilt; past 45° the cube is nearer a different way of
    /// being held, and saying so is the right answer rather than a failure.
    static func nearestGrip(to rotation: Rotation) -> CubeAlignment {
        var best = CubeAlignment.identity
        var bestAgreement = -9.0
        for candidate in everyGrip {
            let agreement = candidate.rotation.agreement(with: rotation)
            if agreement > bestAgreement {
                bestAgreement = agreement
                best = candidate.alignment
            }
        }
        return best
    }

    // MARK: - Calibration

    /// What turns the cube's own idea of its orientation into the child's.
    ///
    /// Not snapped to one of the twenty-four, deliberately. The offset between
    /// the two frames is whatever it is — the cube's sensor was zeroed at some
    /// arbitrary moment — and rounding it to a right angle would bake in up to
    /// 45° of error, which is the whole budget. Left alone, the offset cancels
    /// exactly and only how squarely the cube was being held at the time
    /// matters.
    private(set) var calibration: Rotation?

    var isCalibrated: Bool { calibration != nil }

    /// Pin the two frames together, from a moment when the grip is known.
    mutating func calibrate(sensor: Quaternion, isBeingHeldAs grip: CubeAlignment) {
        guard sensor.isUsable else { return }
        calibration = Self.rotation(of: grip).times(Rotation(sensor).inverse)
    }

    mutating func forget() { calibration = nil }

    /// How the cube is being held now.
    func grip(sensor: Quaternion) -> CubeAlignment? {
        guard let calibration, sensor.isUsable else { return nil }
        return Self.nearestGrip(to: calibration.times(Rotation(sensor)))
    }
}
