import Foundation

/// What to call each of a smart cube's faces on screen.
///
/// A smart cube knows its own faces absolutely — each one has a sensor, and
/// each one is a colour. The face it calls R is its red one, welded into the
/// plastic, for ever. So when a turn arrives there is no doubt about what
/// physically moved.
///
/// The only thing left to work out is what that face is called in the picture
/// the child is looking at, and the picture has the same six colours on its
/// six sides. Red is red. That makes this a lookup off the middles — see
/// ``matching(centresSeen:)`` — and a constant until the app itself turns the
/// picture round, which it only does when the plan says so.
///
/// **How the child is holding the cube does not come into it.** That was the
/// premise this file was built on and it was wrong from the start: there were
/// twenty-four candidate ways of holding it, narrowed by whether each turn
/// matched the move being asked for, thrown away and re-opened when they kept
/// disagreeing, with a motion sensor casting a vote. Every round of "it turns
/// the opposite side" came out of that machinery, and none of it was answering
/// a question the cube had not already answered.
///
/// The rotation is still needed, because saying a whole position in the
/// picture's terms means turning it — but which rotation is determined by the
/// colours, not searched for.
///
/// Checked by `Tools/CubeReference/alignment.py`: 25,920 turns renamed into
/// the app's words and checked against the turn actually made, and the middles
/// giving the right answer for 500 cubes whose own reported position was wrong
/// — the case where matching by position gave up every time.
struct CubeAlignment: Equatable, Sendable {

    /// How the cube would have to be turned in your hands to be held the way
    /// the app is thinking of it.
    let grip: [Move]

    /// What the app calls each face the cube names. Worked out once, because a
    /// turn arrives every time the child moves and this is read on each one.
    let appFace: [Face: Face]

    private init(grip: [Move]) {
        self.grip = grip
        self.appFace = Self.faces(after: grip)
    }

    /// The cube held exactly the way the app thinks of it.
    static let identity = CubeAlignment(grip: [])

    /// How a smart cube's own frame sits in a child's hands when they hold it
    /// the way the app asks them to.
    ///
    /// These cubes number their faces against a fixed orientation — white on
    /// top, green at the front, red on the right. That was established by
    /// asking a cube: eight turns, each named by colour rather than by a side
    /// of the screen, so that how it was being held could not come into the
    /// answer. The app asks the child to hold theirs yellow on top and green
    /// at the front. Those are not
    /// the same way up, and the difference is half a turn:
    ///
    ///     U->D   R->L   F->F   D->U   L->R   B->B
    ///
    /// Top and bottom swapped, left and right swapped, front and back alone —
    /// which is what "it turns the opposite side" was, every time it was
    /// reported. Reading a turn as though the cube's frame and the child's were
    /// the same is wrong on four of the six faces, and no colour, table or
    /// motion sensor could have made it right.
    ///
    /// Worked out from the two colour schemes rather than written down as a
    /// rotation, so it stays true if either of them is ever changed.
    static let asTheChildIsAskedToHoldIt: CubeAlignment = {
        var wanted: [Face: Face] = [:]
        for face in Face.allCases {
            guard let home = CubeColourScheme.face(forCentre: .onTheCubesOwnFace(face)) else {
                return .identity
            }
            wanted[face] = home
        }
        for grip in allGrips {
            let candidate = CubeAlignment.identity.regripped(by: grip)
            if candidate.appFace == wanted { return candidate }
        }
        return .identity
    }()

    /// The move the child actually made, said in the app's words.
    func appMove(for cubeMove: Move) -> Move? {
        guard let face = cubeMove.base.face, let mapped = appFace[face] else { return nil }
        guard let base = MoveBase(rawValue: mapped.letter) else { return nil }
        return Move(base, cubeMove.amount)
    }

    /// The cube's own position, said the way the app is holding it.
    func appState(of cubeState: CubeState) -> CubeState {
        Self.regripping(cubeState, by: grip)
    }

    /// A position the app knows about, said the way the cube thinks of itself.
    ///
    /// The camera is the one thing that can see the cube as it really is, so
    /// after a scan the cube's own idea of itself is corrected to match rather
    /// than left to disagree. Turning a grip back is just turning it the other
    /// way: checked in `Tools/CubeReference` over 200 scrambles under every
    /// grip, and exact every time.
    func cubeState(of appState: CubeState) -> CubeState {
        Self.regripping(appState, by: Move.invert(grip))
    }

    /// The child turned the whole cube round: the app's frame moved with them,
    /// the cube's frame did not.
    func regripped(by rotations: [Move]) -> CubeAlignment {
        let spins = rotations.filter(\.isWholeCubeTurn)
        return spins.isEmpty ? self : CubeAlignment(grip: grip + spins)
    }

    // MARK: - Working it out

    enum Match: Equatable {
        /// One grip fits: this is how the cube is being held.
        case found(CubeAlignment)
        /// Several grips fit, which happens when the cube looks the same from
        /// more than one side — in practice, when it is solved. There is
        /// nothing to solve from there, so nothing is lost by not knowing.
        case tooSymmetricToTell
        /// No grip fits. The cube's own idea of itself has drifted from the
        /// cube in the child's hands, so its turns cannot be trusted.
        case cubeDisagrees
    }

    /// Where the cube's own faces have got to, read straight off the middles.
    ///
    /// **This is not a search and not a guess.** A cube's middles never move
    /// relative to one another, so the face the cube calls R is its red one,
    /// for ever, and the answer is simply whichever face the camera found red
    /// on. Two sets of middles, one bijection, done.
    ///
    /// It matters that this does not look at where the *pieces* are. Lining up
    /// by position fails exactly when the cube's own idea of where its pieces
    /// are has drifted — which is the reason a child reaches for the camera in
    /// the first place, so it failed in the one case it was needed. Then
    /// twenty-four candidates came back to be whittled down by turns, and the
    /// turns in the meantime were read with whichever happened to be first.
    ///
    /// Checked over 500 cubes with a wrong reported position, held every way
    /// round, in `Tools/CubeReference/alignment.py`: the middles gave the right
    /// answer every time and position matching gave up every time.
    static func matching(centresSeen: [Face: CubeColour]) -> CubeAlignment? {
        var wanted: [Face: Face] = [:]
        for face in Face.allCases {
            let colour = CubeColour.onTheCubesOwnFace(face)
            guard let seenOn = centresSeen.first(where: { $0.value == colour })?.key else {
                return nil
            }
            wanted[face] = seenOn
        }
        guard Set(wanted.values).count == Face.allCases.count else { return nil }
        return allGrips.lazy.map { CubeAlignment(grip: $0) }.first { $0.appFace == wanted }
    }

    /// Work out how the cube is being held, from what it says it looks like
    /// against what the camera saw.
    static func matching(cube: CubeState, scanned: CubeState) -> Match {
        let hits = allGrips.filter { regripping(cube, by: $0) == scanned }
        guard let only = hits.first else { return .cubeDisagrees }
        guard hits.count == 1 else { return .tooSymmetricToTell }
        return .found(CubeAlignment(grip: only))
    }

    /// Where each face ends up after these whole-cube turns, read straight off
    /// the middles: turn a solved cube and whatever letter is sitting in a
    /// place is the face that moved there.
    private static func faces(after rotations: [Move]) -> [Face: Face] {
        // Followed through the raw geometry, because ``CubeState/applying(_:)``
        // renames the faces after a rotation so that a solved cube still reads
        // as solved. That is right for solving and fatal here: it means a
        // solved cube turned any way round comes back solved, every centre
        // reads as its own face, and this map came out as the identity for all
        // twenty-four ways of holding a cube.
        //
        // Which is the whole of "it turns the opposite side". With every map an
        // identity, no turn was ever renamed, so every turn was read in the
        // cube's own frame — half a turn from the hand holding it. It also
        // quietly disabled everything built on top: no grip could be told from
        // another, so matching off the middles found nothing and the way the
        // child is asked to hold the cube collapsed to the identity too.
        //
        // The reference has always used a raw permutation here, so the two were
        // checking different things and the 25,920 turns it renamed correctly
        // said nothing about this.
        var map: [Face: Face] = [:]
        for face in Face.allCases {
            let landing = CubeGeometry.follow(sticker: face.centreIndex, through: rotations)
            map[face] = Face.allCases.first { $0.centreIndex == landing } ?? face
        }
        return map
    }

    /// Turning the cube in your hands: the squares move, and then every centre
    /// is called by its own name again, because the cube itself has not
    /// changed — only the way you are looking at it.
    private static func regripping(_ state: CubeState, by rotations: [Move]) -> CubeState {
        rotations.reduce(state) { $0.applying($1).relabelled() }
    }

    /// The twenty-four ways a cube can be held: pick a face to put on top, then
    /// one of four ways to turn it round.
    static let allGrips: [[Move]] = {
        let toTop: [[Move]] = [
            [],
            [Move(.x)], [Move(.x, .half)], [Move(.x, .counterClockwise)],
            [Move(.z)], [Move(.z, .counterClockwise)],
        ]
        let spin: [[Move]] = [
            [],
            [Move(.y)], [Move(.y, .half)], [Move(.y, .counterClockwise)],
        ]
        var grips: [[Move]] = []
        // Told apart by where the middles land, followed through the raw
        // geometry.
        //
        // This used to tell them apart by turning a solved cube and comparing
        // the result, and ``CubeState/applying(_:)`` renames the faces after a
        // rotation so that a solved cube still reads as solved. So all
        // twenty-four came back identical, twenty-three were thrown away as
        // duplicates, and this list held exactly one way of holding a cube:
        // the identity.
        //
        // Which is the whole of "it turns the opposite side", and it survived
        // fixing the very same trap one level down in ``faces(after:)`` —
        // that fix computed a correct map for every grip in a list that had
        // only one grip in it. It also meant the way the child is asked to
        // hold the cube could not be found and fell back to the identity;
        // that lining up off the middles found nothing; and that throwing the
        // grip away and learning it again from the turns re-opened a single
        // candidate, so it was "settled" on the identity the moment it was
        // re-opened. Every one of those was visible in a move log before the
        // cause was.
        var seen: Set<[Int]> = []
        for first in toTop {
            for second in spin {
                let grip = first + second
                let middles = Face.allCases.map {
                    CubeGeometry.follow(sticker: $0.centreIndex, through: grip)
                }
                if seen.insert(middles).inserted {
                    grips.append(grip)
                }
            }
        }
        return grips
    }()
}
