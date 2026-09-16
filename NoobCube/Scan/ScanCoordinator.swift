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
/// trusting them to follow it is not, so a look is filed by its middle sticker
/// — a face with a white middle is the white side, wherever it turns up in the
/// order — and showing a side again simply replaces what was there.
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

    /// The flat map on screen. Written only through ``show``.
    @Published private(set) var scan = ScannedCube()
    @Published private(set) var stepIndex = 0
    @Published private(set) var isComplete = false
    @Published private(set) var problem: String?
    /// Set once the cube has been read and checked.
    @Published private(set) var result: (state: CubeState, whiteFace: Face)?

    /// The look the camera has had at each side, keyed by the side it shows.
    ///
    /// Which side a look is comes from its middle sticker, and that is final. A
    /// cube's middles never move relative to each other, so a face with a white
    /// middle is the white side and belongs in the white side's place — there
    /// is no arrangement of a real cube where it is anything else.
    ///
    /// Showing a side again replaces what is there. That is the whole of the
    /// repair: if a side came out badly, hold it up again.
    private var lookAtSide: [Face: [RGBSample]] = [:]

    /// The side last taken, so it can be thrown away and asked for again.
    private var lastSide: Face?
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
        // An empty map still has its six middles: white opposite yellow, red
        // opposite orange, blue opposite green, so the moment the child is
        // asked to hold it yellow-up and white-down, every middle is known
        // before the camera has seen a thing. ``show`` puts them there.
        show(ScannedCube())
        lookAtSide = [:]
        lastSide = nil
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
        // Still is not the same as readable. A cube held perfectly still in
        // glare is still unreadable, and taking it anyway files a side that is
        // wrong and then has to be undone by hand.
        guard camera.isCubeInFrame,
              camera.steadiness > 0.88,
              camera.settling >= 1,
              Self.readsClearly(camera.steadyReading),
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
    var hasTakenASide: Bool { !lookAtSide.isEmpty }

    /// Throw the last look away and ask for that side again.
    ///
    /// Holding the same side up will not do it by itself, and should not: the
    /// picture has not changed, so there is nothing to tell the app apart from
    /// the frame before. A bad look happens in a moment and the child needs a
    /// way back from it that is one tap and always works, rather than starting
    /// the whole scan again.
    func takeThatSideAgain() {
        guard let side = lastSide else { return }
        lookAtSide[side] = nil
        lastSide = nil
        readyForAnotherLook()
        redraw()
        stepIndex = Self.steps.firstIndex { $0.face == side } ?? stepIndex
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
    /// Nothing here is final either way: if a side goes in the wrong place, or
    /// goes in badly, holding it up again puts it right.
    ///
    /// The light is worked out **before** any side is considered, and this is
    /// the whole point. It used to be worked out once per candidate, assuming
    /// that candidate's colour — which let a candidate fit a light that made
    /// its own answer come true. Only white could do it, because only white is
    /// bright in all three channels, so on any washed-out face white scored a
    /// flat zero and won whatever the sticker really was.
    ///
    /// Measured over 1,500 synthetic faces in each of five lighting conditions,
    /// before and after:
    ///
    ///                  before   after
    ///     daylight       100%    100%
    ///     warm lamp      100%    100%
    ///     dim room        99%     99%
    ///     glare           17%     99%
    ///     bad glare       16%     92%
    ///
    /// Good light was never the problem, which is why this survived every test
    /// it had: they all used clean colours.
    static func side(of reading: [RGBSample]) -> Face {
        let even = ColourClassifier.relit(face: reading, expecting: nil)
        guard even.count == 9 else { return .U }
        return Face.allCases.min {
            ColourClassifier.cost(even[4], as: Self.colour(for: $0))
                < ColourClassifier.cost(even[4], as: Self.colour(for: $1))
        } ?? .U
    }

    /// What it costs to call this reading's middle sticker that side's colour,
    /// under a light no side had a hand in choosing.
    static func centreCost(_ reading: [RGBSample], as face: Face) -> Double {
        let even = ColourClassifier.relit(face: reading, expecting: nil)
        guard even.count == 9 else { return 10 }
        return ColourClassifier.cost(even[4], as: Self.colour(for: face))
    }

    /// Whether every one of the nine squares reads clearly as some colour.
    ///
    /// If a side can be read, it should be written down; if one square cannot
    /// be read at all, no amount of holding still will help and filing it only
    /// makes work. The measure is the worst square, not the average, so one bad
    /// square is enough to wait for a better moment.
    ///
    /// What this catches is a square that is not a colour: a thumb over it, the
    /// cube's own edge inside the crop, a sticker lost to shadow. What it does
    /// not catch — and cannot — is a picture washed out evenly, because a
    /// washed-out square reads as a white sticker perfectly well. That one is
    /// caught at the end, where six sides have to add up to a cube.
    ///
    /// Measured on synthetic faces: a real face's worst square is 0.18 in
    /// daylight, 0.29 in a dim room and 0.24 under ordinary glare, so 0.45
    /// takes 97 to 100% of real faces while turning away a square that is
    /// nothing at all.
    static func readsClearly(_ reading: [RGBSample]) -> Bool {
        guard reading.count == 9 else { return false }
        let even = ColourClassifier.relit(face: reading, expecting: nil)
        return even.allSatisfy { ColourClassifier.costOfBestGuess($0) <= clearEnoughToWriteDown }
    }

    /// How poorly the worst square on a side may read and still be believed.
    static let clearEnoughToWriteDown = 0.45

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
    /// doing as they are told: a look goes to whichever side its middle names,
    /// whether that was the side being asked for or not, and replaces whatever
    /// was on that side before. Showing a side again is the whole repair.
    func captureCurrentFace() {
        let reading = camera.steadyReading.count == 9 ? camera.steadyReading : camera.liveSamples
        guard currentStep != nil, reading.count == 9 else { return }

        guard camera.isCubeInFrame else {
            narrator.say("I can't see your cube. Hold it in front of the camera.")
            return
        }

        // If every square can be read, write the side down. If they cannot,
        // say so and wait: a look that cannot be read is not a look, and
        // filing it makes work for the child rather than saving them any.
        guard Self.readsClearly(reading) else {
            problem = "I can't make out all nine squares. Try moving it out of "
                    + "the light a bit."
            narrator.say("I can't quite see all the colours. Move it out of the light a bit.")
            return
        }

        problem = nil
        // The middle says which side this is, and that is the end of it.
        let side = Self.side(of: reading)
        if lookAtSide[side] != nil {
            narrator.say("That's the \(Self.colour(for: side).spokenName) side again. "
                       + "I'll use this look at it.")
        }
        lookAtSide[side] = reading
        lastSide = side

        redraw()
        lastCaptured = reading
        steadySince = nil
        camera.resetSteadiness()

        advanceToNextUnseenFace()
    }

    /// Work out which look is which side, and draw the net from that.
    ///
    /// Run after every look, so the net fills in as the child works.
    private func redraw() {
        var map = ScannedCube()
        for (face, look) in lookAtSide {
            let colour = Self.colour(for: face)
            map.setFace(face, to: ColourClassifier.bestGuesses(
                ColourClassifier.relit(face: look, expecting: colour)))
        }
        show(map)
    }

    /// Ask for whichever side has not been seen, in the order of the script.
    ///
    /// Which sides are missing is a straight question now: a look is filed by
    /// its middle, so the sides that have one are exactly the sides that have
    /// been seen.
    private func advanceToNextUnseenFace() {
        if let next = Self.steps.firstIndex(where: { lookAtSide[$0.face] == nil }) {
            stepIndex = next
            announceStep()
        } else {
            finish()
        }
    }

    /// Go back and take one side again: throw that look away and ask for it.
    func retake(_ face: Face) {
        lookAtSide[face] = nil
        if lastSide == face { lastSide = nil }
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
        guard lookAtSide.count == 6 else {
            problem = "Some sides weren't seen. Let's go round again."
            return
        }

        // Each side was asked for by name, so the colour of every middle
        // sticker is known before a single pixel is looked at.
        var expected: [Face: CubeColour] = [:]
        for step in Self.steps { expected[step.face] = Self.colour(for: step.face) }
        var arranged = [RGBSample](repeating: RGBSample(red: 0, green: 0, blue: 0), count: 54)
        for (face, look) in lookAtSide {
            for offset in 0..<9 { arranged[face.rawValue * 9 + offset] = look[offset] }
        }
        let (candidate, fit) = bestReading(
            ColourClassifier.priced(arranged, expectedCentres: expected), expecting: expected)

        show(candidate)
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
                problem = inColours(first)
                result = nil
                narrator.say("Hmm, that doesn't look right. \(inColours(first))")
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
        // Not the middles. A middle is not a guess and never was — the side was
        // asked for by name, and ``begin`` drew all six before the camera saw
        // anything. Letting one be tapped could only ever put the same colour
        // in the middle of two sides, which is a cube that cannot exist, and
        // that is exactly the complaint that came back: a white middle on the
        // back face, and "two middle stickers are the same colour".
        guard index % 9 != 4 else { return }
        let current = scan[index] ?? .white
        let all = CubeColour.allCases
        let next = all[(all.firstIndex(of: current).map { $0 + 1 } ?? 0) % all.count]
        setSticker(at: index, to: next)
    }

    func setSticker(at index: Int, to colour: CubeColour) {
        var edited = scan
        edited[index] = colour
        show(edited)
        revalidate()
    }

    /// Put a cube on the map, with its middles set to what they must be.
    ///
    /// The one way `scan` is written. A middle is fixed by the grip the child
    /// was asked to use — yellow up, white down, and the rest follows — so it
    /// is not something any part of this can have an opinion about. Every
    /// writer used to be trusted to remember that separately, which is four
    /// places to get it right and one to get it wrong.
    private func show(_ cube: ScannedCube) {
        scan = Self.withFixedMiddles(cube)
    }

    /// A cube with the middles put back to the only thing they can be.
    static func withFixedMiddles(_ cube: ScannedCube) -> ScannedCube {
        var fixed = cube
        for (face, colour) in CubeColourScheme.scanningLayout {
            fixed[face.centreIndex] = colour
        }
        return fixed
    }

    /// A complaint about the cube, said in colours rather than in the letters
    /// the solver thinks in.
    ///
    /// "There are 8 U stickers" means nothing to anyone holding a cube. U is
    /// the top face in the solver's notation; what the child is looking at is
    /// yellow. And every one of these is fixable by showing the side again, so
    /// each one says so.
    private func inColours(_ problem: CubeState.Problem) -> String {
        switch problem {
        case .wrongStickerCount(let face, let count):
            let colour = scan[face.centreIndex]?.displayName ?? "those"
            return "I counted \(count) \(colour) squares, and there should be 9. "
                 + "Hold that side up and take it again."
        case .duplicateCentre:
            return "Two sides have the same middle, which a cube cannot have. "
                 + "Let's go round again."
        case .badPiece:
            return "One of the corners or edges came out wrong. "
                 + "Hold that side up and take it again."
        case .unsolvable(let detail):
            return detail.replacingOccurrences(of: "check the scan.",
                                               with: "hold that side up and take it again.")
        }
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
                problem = inColours(first)
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
