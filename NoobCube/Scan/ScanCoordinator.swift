import Combine
import SwiftUI

/// Walks the child through showing the app all six sides.
///
/// They are asked to hold the cube with yellow on top and white underneath and
/// keep it that way, so every side is seen the right way up and the flat net
/// fills in anchored the way they are holding it. The top and the bottom come
/// first, which settles the grip before anything else; after that it is one
/// easy spin at a time round the four sides.
///
/// None of it is compulsory. Guiding a five year old is worth doing and
/// trusting them to follow it is not, so a reading is filed where its middle
/// says it belongs, showing a side again replaces it, and at the end all six
/// are settled together — see ``bestAssignment``.
///
/// The top and bottom are the two that get shown at an angle, so rather than
/// trusting the child to tip the cube exactly right, those two faces are tried
/// at all four rotations and the one that makes a real, solvable cube is kept.
@MainActor
final class ScanCoordinator: ObservableObject {

    struct Step: Identifiable {
        let face: Face
        let title: String
        let spoken: String
        var id: Face { face }
    }

    /// The top and the bottom first, then spin it round for the four sides.
    ///
    /// Yellow up and white down is the grip the whole app is built on, so it is
    /// worth showing those two first: it settles how the cube is being held
    /// before anything else, and gets the two awkward ones out of the way while
    /// the child is still fresh. After that it is one easy turn at a time.
    static let steps: [Step] = [
        Step(face: .U,
             title: "Show me the yellow top",
             spoken: "Hold your cube with yellow on top and white underneath. "
                   + "Keep it that way all the way through. "
                   + "Now tip it forwards so I can see the yellow top."),
        Step(face: .D,
             title: "Now the white bottom",
             spoken: "Nice. Now tip it the other way and show me the white bottom."),
        Step(face: .F,
             title: "Now the green side",
             spoken: "Yellow back on top. Now show me the green side."),
        Step(face: .R,
             title: "Now the orange side",
             spoken: "Keep yellow on top, and spin it round to the orange side."),
        Step(face: .B,
             title: "Now the blue side",
             spoken: "Keep going, the same way round. Show me the blue side."),
        Step(face: .L,
             title: "Last one, the red side",
             spoken: "Last one. Spin it round once more to the red side."),
    ]

    /// The colour of the middle sticker each step is asking for.
    static func colour(for face: Face) -> CubeColour {
        CubeColourScheme.scanningLayout[face] ?? .white
    }

    @Published private(set) var scan = ScannedCube()
    @Published private(set) var stepIndex = 0
    @Published private(set) var isComplete = false
    @Published private(set) var problem: String?
    /// Set once the cube has been read and checked.
    @Published private(set) var result: (state: CubeState, whiteFace: Face)?

    /// Every look the camera has had, in the order they were taken.
    ///
    /// Not six pigeonholes, one per side. Filing each look into a side the
    /// moment it is taken loses sides: a middle sticker read wrongly puts a
    /// look in the wrong place, the side it should have filled still looks
    /// empty, the child shows that side again — and now two of the six looks
    /// are of one side and another has never been seen at all. Measured, that
    /// halved how often a dim room read a cube correctly. Kept as a list, the
    /// six looks are six different sides by construction, and which is which
    /// is worked out from all of them at once.
    private var looks: [[RGBSample]] = []

    /// Which side each look is currently taken to be, best guess so far.
    private var sideOfLook: [Int] = []
    /// When the cube first went still, so a side is taken after a length of
    /// time rather than after a number of frames.
    ///
    /// It used to count frames, which stood in for time well enough while the
    /// counting was driven by the steadiness changing — and became far too
    /// quick the moment it was driven by the frames themselves. Eight frames is
    /// an eighth of a second, which is not long enough to tell a cube being
    /// held up from a cube on its way past.
    private var steadySince: Date?

    /// How long the cube has to be held still before a side is taken by itself.
    private static let holdBeforeTaking = 0.8

    /// What the camera was looking at when a side was last taken.
    ///
    /// After a side is taken the cube is still sitting in front of the lens and
    /// still perfectly still, so without this it is taken again a second later,
    /// and again, and again — and the instruction for the next side is read out
    /// over the top of itself each time. That is the stutter.
    private var lastCaptured: [RGBSample] = []

    /// The side last spoken about, so the same sentence is not started again
    /// from the beginning while it is still being said.
    private var announcedFace: Face?

    let camera: CameraController
    private let narrator: Narrator
    /// The camera is its own observable object, so its changes are passed on
    /// here; otherwise the live squares and the steadiness ring never redraw.
    private var cameraObserver: AnyCancellable?

    init(camera: CameraController, narrator: Narrator) {
        self.camera = camera
        self.narrator = narrator
        cameraObserver = camera.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var currentStep: Step? {
        Self.steps.indices.contains(stepIndex) ? Self.steps[stepIndex] : nil
    }

    var scannedFaceCount: Int { scan.scannedFaces.count }

    /// Sides still to be shown, as their middle colours.
    var remainingColours: [CubeColour] {
        Self.steps.filter { !scan.isFaceScanned($0.face) }.map { Self.colour(for: $0.face) }
    }

    /// Sides already seen, as their middle colours.
    var capturedColours: [CubeColour] {
        Self.steps.filter { scan.isFaceScanned($0.face) }.map { Self.colour(for: $0.face) }
    }

    /// The colours under the guide right now, for the nine live squares.
    ///
    /// Relit against the side being asked for, so the squares show what the
    /// app will actually record rather than what the lamp is doing.
    var livePreview: [CubeColour] {
        guard camera.isCubeInFrame, camera.liveSamples.count == 9 else { return [] }
        return ColourClassifier.bestGuesses(relit(camera.liveSamples))
    }

    private func relit(_ samples: [RGBSample]) -> [RGBSample] {
        ColourClassifier.relit(face: samples,
                               expecting: currentStep.map { Self.colour(for: $0.face) })
    }

    /// True once the camera is looking at something other than the side just
    /// taken, so the child can be told to turn the cube rather than being
    /// taken through the same side again.
    var isStillOnTheSideJustTaken: Bool {
        guard !lastCaptured.isEmpty else { return false }
        let reading = camera.steadyReading.count == 9 ? camera.steadyReading : camera.liveSamples
        return !hasMovedOn(to: reading)
    }

    // MARK: - Running the scan

    func begin() {
        scan = ScannedCube()
        // Draw the six middles straight away. White is opposite yellow, red
        // opposite orange, blue opposite green, so the moment the child is
        // asked to hold it yellow-up and white-down, every middle is known
        // before the camera has seen a thing.
        for (face, colour) in CubeColourScheme.scanningLayout {
            scan[face.centreIndex] = colour
        }
        looks = []
        sideOfLook = []
        stepIndex = 0
        isComplete = false
        problem = nil
        result = nil
        steadySince = nil
        lastCaptured = []
        announcedFace = nil
        // Every frame gets a chance to be the one that takes the side, rather
        // than only the frames where the steadiness happened to change.
        camera.onFrame = { [weak self] in self?.considerAutoCapture() }
        camera.start()
        camera.resetSteadiness()
        announceStep()
    }

    /// Say what to do next, once.
    ///
    /// `force` is for the child pressing the repeat button, which should say it
    /// again however recently it was said.
    func announceStep(force: Bool = false) {
        guard let step = currentStep else { return }
        guard force || announcedFace != step.face else { return }
        announcedFace = step.face
        narrator.say(step.spoken)
    }

    func stop() {
        camera.onFrame = nil
        camera.stop()
    }

    /// Called every frame: take the face automatically once the cube has been
    /// held still long enough for the reading to settle.
    func considerAutoCapture() {
        guard currentStep != nil, !isComplete else { return }
        // Holding the cube still is not a reason to take the same picture
        // twice — a camera that does that is the stutter this app started
        // with. Taking a side again is what ``takeThatSideAgain`` is for.
        guard camera.isCubeInFrame,
              camera.steadiness > 0.88,
              camera.settling >= 1,
              hasMovedOn(to: camera.steadyReading) else {
            steadySince = nil
            return
        }
        let since = steadySince ?? Date()
        steadySince = since
        if Date().timeIntervalSince(since) >= Self.holdBeforeTaking {
            captureCurrentFace()
        }
    }

    /// Whether there is a look to throw away.
    var hasTakenASide: Bool { !looks.isEmpty }

    /// Throw the last look away and ask for that side again.
    ///
    /// Holding the same side up will not do it by itself, and should not: the
    /// picture has not changed, so there is nothing to tell the app apart from
    /// the frame before. A bad look happens in a moment and the child needs a
    /// way back from it that is one tap and always works, rather than starting
    /// the whole scan again.
    func takeThatSideAgain() {
        guard !looks.isEmpty else { return }
        looks.removeLast()
        readyForAnotherLook()
        redraw()
        stepIndex = min(looks.count, Self.steps.count - 1)
        isComplete = false
        problem = nil
        result = nil
        announceStep(force: true)
    }

    /// Tapping a side in the flat net means "that one came out wrong".
    func retakeFace(containing index: Int) {
        guard let face = Face(rawValue: index / 9), scan.isFaceScanned(face) else { return }
        retake(face)
    }

    /// Ready to look at the same thing again: forget what was last taken, so
    /// the very same picture is allowed to be taken a second time.
    private func readyForAnotherLook() {
        lastCaptured = []
        steadySince = nil
        camera.resetSteadiness()
    }

    /// Whether the camera is looking at something other than the side just
    /// taken. A cube turned to a new side changes far more than a hand shaking.
    private func hasMovedOn(to reading: [RGBSample]) -> Bool {
        !Self.looksLikeTheSameSide(reading, lastCaptured)
    }

    /// Which side a reading is, going by its middle sticker.
    ///
    /// The app still guides the child round the cube, but they are five: they
    /// will show a side that was not asked for, or the same one twice, or
    /// start again half way round. So a reading is filed where its middle says
    /// it belongs rather than where it was expected, and it replaces whatever
    /// was there — the last look at a side always wins.
    ///
    /// One middle sticker is not to be trusted on its own; in a dim room it
    /// reads wrong about one time in five. That is why nothing here is final:
    /// showing the side again puts it right, and ``bestAssignment`` settles all
    /// six together at the end, where a bad middle cannot take a side that
    /// another reading explains better.
    private func face(of reading: [RGBSample]) -> Face {
        Face.allCases.min { centreCost(reading, as: $0) < centreCost(reading, as: $1) }
            ?? currentStep?.face ?? .U
    }

    /// What it costs to call this reading's middle sticker that side's colour.
    private func centreCost(_ reading: [RGBSample], as face: Face) -> Double {
        let colour = Self.colour(for: face)
        let relit = ColourClassifier.relit(face: reading, expecting: colour)
        return ColourClassifier.cost(relit[4], as: colour)
    }

    /// Two readings of the same nine squares, near enough.
    ///
    /// Raw pixels rather than colour names: what colour a square is called is
    /// the unreliable part, and whether the picture changed is not.
    static func looksLikeTheSameSide(_ one: [RGBSample], _ other: [RGBSample]) -> Bool {
        guard one.count == 9, other.count == 9 else { return false }
        var difference = 0.0
        for index in 0..<9 {
            difference += abs(one[index].red - other[index].red)
                + abs(one[index].green - other[index].green)
                + abs(one[index].blue - other[index].blue)
        }
        return difference / 27 <= aDifferentSide
    }

    /// How much the nine readings have to change before this is another side.
    /// A hand shaking moves them a little; turning the cube moves them a lot.
    static let aDifferentSide = 0.07

    /// Take a look at whatever is in front of the camera.
    ///
    /// The app asks for a side at a time, but nothing here depends on the child
    /// doing as they are told: the first six looks are simply kept, and which
    /// one is which side is worked out afterwards from all six together. Once
    /// there are six, another look replaces the one on the side it matches, so
    /// a side that came out wrong is put right by showing it again.
    func captureCurrentFace() {
        let reading = camera.steadyReading.count == 9 ? camera.steadyReading : camera.liveSamples
        guard currentStep != nil, reading.count == 9 else { return }

        guard camera.isCubeInFrame else {
            narrator.say("I can't see your cube. Hold it in front of the camera.")
            return
        }

        problem = nil
        if looks.count < 6 {
            looks.append(reading)
        } else {
            // Six looks already, so this one is a second go at a side. It takes
            // the place of whichever look it matches best: the last look at a
            // side always wins.
            let side = face(of: reading)
            let replacing = sideOfLook.firstIndex(of: side.rawValue) ?? 0
            narrator.say("That's the \(Self.colour(for: side).spokenName) side again. "
                       + "I'll use this look at it.")
            looks[replacing] = reading
        }
        redraw()
        lastCaptured = reading
        steadySince = nil
        camera.resetSteadiness()

        advanceToNextUnseenFace()
    }

    /// Work out which look is which side, and draw the net from that.
    ///
    /// Run after every look rather than only at the end, so the net fills in as
    /// the child works and quietly puts itself right as later looks explain a
    /// side better than an earlier one did.
    private func redraw() {
        sideOfLook = Self.sides(for: looks) { self.centreCost($0, as: $1) }

        scan = ScannedCube()
        for (face, colour) in CubeColourScheme.scanningLayout {
            scan[face.centreIndex] = colour
        }
        for (index, look) in looks.enumerated() {
            guard let face = Face(rawValue: sideOfLook[index]) else { continue }
            let colour = Self.colour(for: face)
            var guesses = ColourClassifier.bestGuesses(
                ColourClassifier.relit(face: look, expecting: colour))
            // The middle is never a guess: a side's middle is fixed by the way
            // the child was asked to hold the cube, so it is drawn as that and
            // the same colour can never appear in the middle of two sides.
            guesses[4] = colour
            scan.setFace(face, to: guesses)
        }
    }

    /// Which side each look is, going by the middles and nothing else.
    ///
    /// Good enough to draw the net with while the child works, and to narrow
    /// the end of the scan down to a shortlist, but not good enough to decide
    /// anything. One middle sticker reads wrong about one time in five in a dim
    /// room, and swapping two looks whose middles have been read as each other
    /// costs exactly the same as getting them right — a tie the middles have no
    /// way to break. Breaking it takes all 54 stickers; see ``bestAssignment``.
    static func sides(for looks: [[RGBSample]],
                      cost: ([RGBSample], Face) -> Double) -> [Int] {
        guard !looks.isEmpty else { return [] }
        let table = looks.map { look in Face.allCases.map { cost(look, $0) } }
        return ranked(table).first ?? Array(0..<looks.count)
    }

    /// Every way of putting these looks on sides, no side twice, best first.
    ///
    /// `table[look][side]` is what it costs to call that look that side.
    static func ranked(_ table: [[Double]]) -> [[Int]] {
        let count = table.count
        guard count > 0 else { return [] }
        return everyAssignment
            .map { order -> (order: [Int], total: Double) in
                var total = 0.0
                for index in 0..<count { total += table[index][order[index]] }
                return (Array(order.prefix(count)), total)
            }
            .sorted { $0.total < $1.total }
            .map(\.order)
    }

    /// Ask for the next side in the script.
    ///
    /// By how many looks we have, not by which sides the app reckons it is
    /// still missing. Those two come apart exactly when a look has been put on
    /// the wrong side, and then asking for the side that looks missing asks the
    /// child for one they have already shown — so two looks end up being of the
    /// same side and another is never seen at all. The script just counts to
    /// six. Which look is which side is a separate question, and one that is
    /// better answered with all six in hand.
    private func advanceToNextUnseenFace() {
        if looks.count < Self.steps.count {
            stepIndex = looks.count
            announceStep()
        } else {
            finish()
        }
    }

    /// Go back and take one side again: throw that look away and ask for it.
    func retake(_ face: Face) {
        if let index = sideOfLook.firstIndex(of: face.rawValue) {
            looks.remove(at: index)
        }
        readyForAnotherLook()
        redraw()
        if let index = Self.steps.firstIndex(where: { $0.face == face }) {
            stepIndex = index
            isComplete = false
            result = nil
            problem = nil
            announceStep(force: true)
        }
    }

    // MARK: - Settling the scan

    private func finish() {
        guard looks.count == 6 else {
            problem = "Some sides weren't seen. Let's go round again."
            return
        }

        // Each side was asked for by name, so the colour of every middle
        // sticker is known before a single pixel is looked at.
        var expected: [Face: CubeColour] = [:]
        for step in Self.steps { expected[step.face] = Self.colour(for: step.face) }
        let (candidate, fit) = bestAssignment(of: looks, expecting: expected)

        scan = candidate
        isComplete = true

        // Before asking whether this cube can exist, ask whether it is the one
        // in front of the camera. A reading this poor is not a cube being
        // misread, it is something else being read.
        guard fit <= ColourClassifier.tooPoorToBelieve else {
            problem = "I couldn't see your cube clearly enough. Let's go round again."
            result = nil
            narrator.say("Hmm, I couldn't see that clearly enough. "
                       + "Let's try again somewhere brighter.")
            return
        }

        do {
            let converted = try candidate.cubeState()
            let problems = converted.state.validate()
            if let first = problems.first {
                problem = first.message
                result = nil
                narrator.say("Hmm, something doesn't look right. \(first.message) Tap any square to fix it.")
            } else {
                problem = nil
                result = converted
                narrator.say("Got it! That's your whole cube.")
            }
        } catch {
            problem = error.localizedDescription
            result = nil
        }
    }

    /// Work out which reading is which side, and read the cube.
    ///
    /// Filing each side by its own middle sticker is not good enough — in a dim
    /// room a middle reads wrong about one time in five, and confidently. Nor
    /// is requiring the six to go onto six different sides enough on its own:
    /// when two middles are read as each other, swapping the pair costs exactly
    /// what getting them right costs, and the middles cannot break that tie.
    ///
    /// So the middles only narrow it to a shortlist. Each one on the shortlist
    /// is settled properly and judged on how well it accounts for all 54
    /// stickers, which is the same test that picks the turn of the top and
    /// bottom. Measured on cubes with one middle painted the wrong colour, the
    /// middles alone never got it right and the shortlist and fit together
    /// always did.
    ///
    /// Measured end to end over random scrambles in a dim warm room, 63% of
    /// cubes come out perfect whether the sides are shown in the order asked
    /// or in any order at all. Trusting the order managed 61% when it was
    /// obeyed and nothing whatsoever when it was not.
    private func bestAssignment(of looks: [[RGBSample]],
                                expecting expected: [Face: CubeColour])
    -> (cube: ScannedCube, fit: Double) {
        let cost = looks.map { look in Face.allCases.map { centreCost(look, as: $0) } }

        var best: (cube: ScannedCube, fit: Double)?
        var first: (cube: ScannedCube, fit: Double)?
        for order in Self.ranked(cost).prefix(Self.assignmentsTried) {
            var arranged = [RGBSample](repeating: looks[0][0], count: 54)
            for (index, side) in order.enumerated() {
                for offset in 0..<9 { arranged[side * 9 + offset] = looks[index][offset] }
            }
            // Priced once for this arrangement and reused for all sixteen
            // turns of the top and bottom: turning stickers on the spot does
            // not change what any of them costs to name.
            let trial = bestReading(ColourClassifier.priced(arranged, expectedCentres: expected),
                                    expecting: expected)
            if first == nil { first = trial }
            guard let converted = try? trial.cube.cubeState(),
                  converted.state.isValid else { continue }
            if trial.fit < (best?.fit ?? .greatestFiniteMagnitude) { best = trial }
        }
        return best ?? first ?? (cube: ScannedCube(), fit: .greatestFiniteMagnitude)
    }

    /// How many of the 720 ways to file six looks are settled properly.
    ///
    /// The middles put the right one first about four times in five, and in
    /// the top eight better than 97 times in a hundred. Each one is settled at
    /// all sixteen turns of the top and bottom, so this is a hundred and
    /// twenty-eight settles — which is only affordable because a scan is
    /// priced once per arrangement rather than once per settle.
    private static let assignmentsTried = 8

    /// Every way of filing six readings as six sides.
    static let everyAssignment: [[Int]] = {
        var result: [[Int]] = []
        var order: [Int] = []
        func extend() {
            if order.count == 6 { result.append(order); return }
            for side in 0..<6 where !order.contains(side) {
                order.append(side)
                extend()
                order.removeLast()
            }
        }
        extend()
        return result
    }()

    /// Read the whole scan, trying the top and bottom at all four rotations.
    ///
    /// Those two are the awkward ones to hold square to the camera. The turn
    /// has to be tried before the colours are settled rather than after:
    /// settling fits whole pieces into slots, so where a sticker sits is part
    /// of the reading.
    ///
    /// Of the turns that make a cube that could exist, the winner is whichever
    /// accounts best for the pixels. Being a real cube is not enough on its own
    /// — a wrong turn can still land on one — but it cannot also explain the
    /// colours better than the truth does. The straight reading is kept as the
    /// tie-break, because the child was probably holding it as asked.
    private func bestReading(_ priced: ColourClassifier.Priced,
                             expecting expected: [Face: CubeColour])
    -> (cube: ScannedCube, fit: Double) {
        var straight: (cube: ScannedCube, fit: Double)?
        var best: (cube: ScannedCube, fit: Double)?
        for topTurns in 0..<4 {
            let top = priced.turning(.U, quarterTurns: topTurns)
            for bottomTurns in 0..<4 {
                let settled = ColourClassifier.settle(
                    top.turning(.D, quarterTurns: bottomTurns), expectedCentres: expected)

                // Kept so there is something to show, and something to complain
                // about, when no turn makes a real cube.
                if topTurns == 0 && bottomTurns == 0 {
                    straight = (ScannedCube(colours: settled.colours.map { Optional($0) }),
                                settled.averageFit)
                }

                // Checking whether a cube could exist is the expensive part —
                // twenty pieces, three parities — and a reading that explains
                // the pixels worse than the best one so far cannot win however
                // real it is. So ask about the fit first, and most of the
                // hundred and twenty-eight readings never get checked at all.
                guard settled.averageFit < (best?.fit ?? .greatestFiniteMagnitude) else { continue }
                let cube = ScannedCube(colours: settled.colours.map { Optional($0) })
                guard let converted = try? cube.cubeState(),
                      converted.state.isValid else { continue }
                best = (cube, settled.averageFit)
            }
        }
        return best ?? straight ?? (cube: ScannedCube(), fit: .greatestFiniteMagnitude)
    }

    // MARK: - Fixing a square by hand

    /// Tapping a square steps it to the next colour.
    func cycleSticker(at index: Int) {
        guard index >= 0, index < 54 else { return }
        let current = scan[index] ?? .white
        let all = CubeColour.allCases
        let next = all[(all.firstIndex(of: current).map { $0 + 1 } ?? 0) % all.count]
        setSticker(at: index, to: next)
    }

    func setSticker(at index: Int, to colour: CubeColour) {
        scan[index] = colour
        revalidate()
    }

    private func revalidate() {
        guard scan.isComplete else {
            result = nil
            return
        }
        do {
            let converted = try scan.cubeState()
            let problems = converted.state.validate()
            if let first = problems.first {
                problem = first.message
                result = nil
            } else {
                problem = nil
                result = converted
            }
        } catch {
            problem = error.localizedDescription
            result = nil
        }
    }
}
