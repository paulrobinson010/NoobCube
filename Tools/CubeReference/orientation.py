"""Which way up the cube is, from its own motion sensor.

The twin of `NoobCube/SmartCube/CubeOrientation.swift`.

A smart cube's face numbers are welded to the plastic, so the position it
reports is right however the child holds it — that never needed a grip. What
needed one is *talking* about it: "turn the right-hand side" means knowing which
side is on their right. The motion sensor answers that outright, and keeps
answering it while the cube is turned about.

The point of this file is one claim: GAN's axes never have to be known. The
sensor's frame and the child's differ by one fixed rotation, and one moment
where the grip is known independently pins it. Everything after cancels.

    python3 Tools/CubeReference/orientation.py
"""
import math
import random

import cube
import alignment

FACES = cube.FACES


def matmul(a, b):
    return [[sum(a[i][k] * b[k][j] for k in range(3)) for j in range(3)]
            for i in range(3)]


def transpose(m):
    return [[m[j][i] for j in range(3)] for i in range(3)]


def quaternion_to_rotation(w, x, y, z):
    size = math.sqrt(w * w + x * x + y * y + z * z) or 1.0
    w, x, y, z = w / size, x / size, y / size, z / size
    return [
        [1 - 2 * (y * y + z * z), 2 * (x * y - z * w),     2 * (x * z + y * w)],
        [2 * (x * y + z * w),     1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
        [2 * (x * z - y * w),     2 * (y * z + x * w),     1 - 2 * (x * x + y * y)],
    ]


def grip_rotation(grip):
    """The rotation a way of holding the cube performs.

    Read off where it sends each face: the six face normals are the six signed
    axes, so each column falls straight out.
    """
    after = alignment.faces_after(grip)          # {cube face: app face}
    m = [[0.0] * 3 for _ in range(3)]
    for cube_face, app_face in after.items():
        src, dst = cube.NORMAL[cube_face], cube.NORMAL[app_face]
        for i in range(3):
            if src[i] == 1:
                for r in range(3):
                    m[r][i] = float(dst[r])
    return m


EVERY_GRIP = [(g, grip_rotation(g)) for g in alignment.GRIPS]


def nearest_grip(m):
    """The way of holding the cube this rotation is nearest to."""
    best, best_agreement = None, -9.0
    for g, gm in EVERY_GRIP:
        agreement = sum(gm[i][j] * m[i][j] for i in range(3) for j in range(3))
        if agreement > best_agreement:
            best, best_agreement = g, agreement
    return best


def random_rotation(rng):
    u1, u2, u3 = rng.random(), rng.random(), rng.random()
    return (math.sqrt(1 - u1) * math.sin(2 * math.pi * u2),
            math.sqrt(1 - u1) * math.cos(2 * math.pi * u2),
            math.sqrt(u1) * math.sin(2 * math.pi * u3),
            math.sqrt(u1) * math.cos(2 * math.pi * u3))


def a_tilt(rng, degrees):
    """Holding a cube not quite square."""
    _, ax, ay, az = random_rotation(rng)
    n = math.sqrt(ax * ax + ay * ay + az * az) or 1
    a = math.radians(degrees)
    s = math.sin(a / 2)
    return quaternion_to_rotation(math.cos(a / 2), ax / n * s, ay / n * s, az / n * s)


# ------------------------------------------------------------------ checking

def check_snapping_tolerance(seed=5):
    """How far off square the cube can be and still be read correctly.

    45° is the halfway point between two ways of holding a cube, so it is the
    most that could ever work; this shows it holds right up to it.
    """
    rng = random.Random(seed)
    print('a cube tilted off square, snapped to the nearest way of holding it')
    for degrees in (0, 20, 40, 44, 46, 60):
        wrong = 0
        for _ in range(400):
            g = rng.choice(alignment.GRIPS)
            wrong += nearest_grip(matmul(a_tilt(rng, degrees), grip_rotation(g))) != g
        print('  tilted %2d degrees:  %3d of 400 wrong' % (degrees, wrong))


def check_the_axes_never_matter(trials=2000, seed=3):
    """One calibration, then every orientation read right — whatever GAN's axes.

    The offset between the cube's frame and the child's is drawn at random each
    time, which covers any convention GAN might have chosen and any moment the
    sensor might have been zeroed at.
    """
    print('one calibration, then reading how it is held')
    for hold in (10, 20, 30, 35):
        rng = random.Random(seed)
        right = total = 0
        for _ in range(trials):
            offset = quaternion_to_rotation(*random_rotation(rng))

            # A moment where the grip is known some other way: from a scan, or
            # from the turns settling it.
            known = rng.choice(alignment.GRIPS)
            q0 = matmul(transpose(offset),
                        matmul(grip_rotation(known), a_tilt(rng, rng.uniform(0, hold))))
            # Not snapped: rounding the offset to a right angle would bake in
            # up to 45 degrees of error, which is the whole budget.
            calibration = matmul(grip_rotation(known), transpose(q0))

            for _ in range(5):
                now = rng.choice(alignment.GRIPS)
                q = matmul(transpose(offset),
                           matmul(grip_rotation(now), a_tilt(rng, rng.uniform(0, hold))))
                right += nearest_grip(matmul(calibration, q)) == now
                total += 1
        print('  held within %2d degrees of square:  %5d/%5d  (%.1f%%)'
              % (hold, right, total, 100 * right / total))
        if hold <= 20:
            assert right == total, (hold, right, total)


def check_a_turn_of_the_whole_cube_is_visible(trials=500, seed=9):
    """The instruction a cube could never follow along with.

    A cube cannot feel itself being turned round in your hands, so "turn the
    cube around" was the one step that still needed a tap. The sensor feels it
    perfectly well.
    """
    rng = random.Random(seed)
    seen = 0
    for _ in range(trials):
        offset = quaternion_to_rotation(*random_rotation(rng))
        before = rng.choice(alignment.GRIPS)
        q0 = matmul(transpose(offset),
                    matmul(grip_rotation(before), a_tilt(rng, rng.uniform(0, 15))))
        calibration = matmul(grip_rotation(before), transpose(q0))

        for spin in ('y', "y'", 'y2', 'x', "x'", 'x2', 'z', "z'", 'z2'):
            after = before + [spin]
            q = matmul(transpose(offset),
                       matmul(grip_rotation(after), a_tilt(rng, rng.uniform(0, 15))))
            got = nearest_grip(matmul(calibration, q))
            assert alignment.faces_after(got) == alignment.faces_after(after), spin
            seen += 1
    print('whole-cube turns felt by the sensor  %d, all of them' % seen)


if __name__ == '__main__':
    check_snapping_tolerance()
    print()
    check_the_axes_never_matter()
    print()
    check_a_turn_of_the_whole_cube_is_visible()
    print()
    print('ALL PASS')
