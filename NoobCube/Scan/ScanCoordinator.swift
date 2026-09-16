import Combine
import SwiftUI

/// Walks the child through showing the app all six sides.
///
/// They are asked to hold the cube with white on the bottom and yellow on top
/// and keep it that way, so every side is seen the right way up and the flat
/// net fills in anchored the way they are holding it. Between sides they only
/// ever spin left, which is the easiest turn to follow.
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

    static let steps: [Step] = [
        Step(face: .F,
             title: "Show me the green side",
             spoken: "Hold your cube with yellow on top and white underneath. "
                   + "Keep it that way. Now show me the green side."),
        Step(face: .R,
             title: "Now the orange side",
             spoken: "Nice. Keep yellow on top, and turn it round to show me the orange side."),
        Step(face: .B,
             title: "Now the blue side",
             spoken: "Keep going. Show me the blue side."),
        Step(face: .L,
             title: "Now the red side",
             spoken: "Nearly there. Show me the red side."),
        Step(face: .U,
             title: "Now the yellow top",
             spoken: "Now tip the cube forwards so I can see the yellow top."),
        Step(face: .D,
             title: "Last one, the white bottom",
             spoken: "Last one. Turn it over and show me the white bottom."),
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

    /// Raw camera readings, kept so the whole scan can be settled at the end.
    private var rawSamples = [RGBSample?](repeating: nil, count: 54)
    private var holdFrames = 0

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
        rawSamples = [RGBSample?](repeating: nil, count: 54)
        stepIndex = 0
        isComplete = false
        problem = nil
        result = nil
        holdFrames = 0
        lastCaptured = []
        announcedFace = nil
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
        camera.stop()
    }

    /// Called every frame: take the face automatically once the cube has been
    /// held still long enough for the reading to settle.
    func considerAutoCapture() {
        guard currentStep != nil, !isComplete else { return }
        guard camera.isCubeInFrame else {
            holdFrames = 0
            return
        }
        guard camera.steadiness > 0.88, camera.settling >= 1 else {
            holdFrames = 0
            return
        }
        // Holding the cube still is not a reason to take a side we have. Said
        // nothing about here: the child is simply not moved on, and the side
        // they are being asked for is still on screen.
        guard sideAlreadyTaken(camera.steadyReading) == nil else {
            holdFrames = 0
            return
        }
        holdFrames += 1
        if holdFrames >= 8 {
            captureCurrentFace()
        }
    }

    /// Whether the camera is looking at something other than the side just
    /// taken. A cube turned to a new side changes far more than a hand shaking.
    private func hasMovedOn(to reading: [RGBSample]) -> Bool {
        !Self.looksLikeTheSameSide(reading, lastCaptured)
    }

    /// The side this reading has already been filed as, if it has.
    ///
    /// Checked against every side taken rather than only the last one. Three
    /// sides of one scan came back as very nearly the same nine readings — the
    /// camera never had the cube in front of it — and all three were kept, so
    /// the net drew a cube with three orange middles. The camera cannot always
    /// tell what it is looking at, but it can tell it is looking at the same
    /// thing again, and that is enough to stop it.
    private func sideAlreadyTaken(_ reading: [RGBSample]) -> Face? {
        Face.allCases.first { face in
            guard scan.isFaceScanned(face) else { return false }
            let stored = (0..<9).compactMap { rawSamples[face.rawValue * 9 + $0] }
            return Self.looksLikeTheSameSide(reading, stored)
        }
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

    /// Record the side the camera is looking at, as the side that was asked for.
    ///
    /// It used to be filed by the colour of its middle sticker instead, so that
    /// showing the sides in any order simply worked. That colour is not good
    /// enough to carry the decision: in a dim warm room the middle reads as the
    /// wrong colour about one time in five, and it reads that wrong colour
    /// confidently, so no threshold rescues it. Filed under the wrong side, the
    /// nine readings are in the wrong box and every square on two sides is
    /// wrong — the scan is finished before it starts.
    ///
    /// Asking for one side at a time and taking the answer at its word is worth
    /// more: the app says which side it wants, and the worst a mistake can do
    /// now is fail the check at the end, where it can be taken again.
    func captureCurrentFace() {
        let reading = camera.steadyReading.count == 9 ? camera.steadyReading : camera.liveSamples
        guard let step = currentStep, reading.count == 9 else { return }

        guard camera.isCubeInFrame else {
            narrator.say("I can't see your cube. Hold it in front of the camera.")
            return
        }

        // The button is there to hurry the app along, not to take a side twice.
        // Say what is actually needed instead.
        if let taken = sideAlreadyTaken(reading) {
            narrator.say("That looks like the \(Self.colour(for: taken).spokenName) side, "
                       + "and I've got that one. Turn the cube to show me the "
                       + "\(Self.colour(for: step.face).spokenName) side.")
            return
        }

        store(samples: reading, on: step.face)
        lastCaptured = reading
        holdFrames = 0
        camera.resetSteadiness()

        advanceToNextUnseenFace()
    }

    /// Move on to whichever side still has not been seen.
    private func advanceToNextUnseenFace() {
        let unseen = Self.steps.firstIndex { !scan.isFaceScanned($0.face) }
        if let unseen {
            stepIndex = unseen
            announceStep()
        } else {
            finish()
        }
    }

    private func store(samples: [RGBSample], on face: Face) {
        for offset in 0..<9 {
            rawSamples[face.rawValue * 9 + offset] = samples[offset]
        }
        // Show the face immediately with a rough guess, so the net fills in as
        // the child works. It is settled properly once all six are in.
        let corrected = ColourClassifier.relit(face: samples,
                                               expecting: Self.colour(for: face))
        var guesses = ColourClassifier.bestGuesses(corrected)

        // The middle is not a guess. The side was asked for by name, and
        // ``begin`` drew all six middles before the camera saw anything —
        // painting a read colour over one threw that away, and the net ended
        // up showing an orange middle on three different sides at once, which
        // is a cube nobody owns.
        guesses[4] = Self.colour(for: face)
        scan.setFace(face, to: guesses)
    }

    /// Go back and take one face again.
    func retake(_ face: Face) {
        scan.clearFace(face)
        for offset in 0..<9 {
            rawSamples[face.rawValue * 9 + offset] = nil
        }
        if let index = Self.steps.firstIndex(where: { $0.face == face }) {
            stepIndex = index
            isComplete = false
            result = nil
            problem = nil
            lastCaptured = []
            announceStep(force: true)
        }
    }

    // MARK: - Settling the scan

    private func finish() {
        guard let samples = completeSamples() else {
            problem = "Some squares weren't seen. Let's go round again."
            return
        }

        // Each side was asked for by name, so the colour of every middle
        // sticker is known before a single pixel is looked at.
        var expected: [Face: CubeColour] = [:]
        for step in Self.steps { expected[step.face] = Self.colour(for: step.face) }
        let (candidate, fit) = bestReading(of: samples, expecting: expected)

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

    private func completeSamples() -> [RGBSample]? {
        var samples: [RGBSample] = []
        samples.reserveCapacity(54)
        for value in rawSamples {
            guard let value else { return nil }
            samples.append(value)
        }
        return samples
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
    private func bestReading(of samples: [RGBSample],
                             expecting expected: [Face: CubeColour])
    -> (cube: ScannedCube, fit: Double) {
        var straight: (cube: ScannedCube, fit: Double)?
        var best: (cube: ScannedCube, fit: Double)?
        for topTurns in 0..<4 {
            for bottomTurns in 0..<4 {
                let settled = ColourClassifier.settle(
                    rawSamples: Self.rotating(samples, top: topTurns, bottom: bottomTurns),
                    expectedCentres: expected)
                let trial = (cube: ScannedCube(colours: settled.colours.map { Optional($0) }),
                             fit: settled.averageFit)
                // Kept so there is something to show, and something to complain
                // about, when no turn makes a real cube.
                if topTurns == 0 && bottomTurns == 0 { straight = trial }
                guard let converted = try? trial.cube.cubeState(),
                      converted.state.isValid else { continue }
                if trial.fit < (best?.fit ?? .greatestFiniteMagnitude) { best = trial }
            }
        }
        return best ?? straight ?? (cube: ScannedCube(), fit: .greatestFiniteMagnitude)
    }

    /// The same readings with the top and bottom faces turned on the spot.
    private static func rotating(_ samples: [RGBSample],
                                 top: Int, bottom: Int) -> [RGBSample] {
        var turned = samples
        for (face, quarterTurns) in [(Face.U, top), (Face.D, bottom)] {
            var grid = (0..<9).map { samples[face.rawValue * 9 + $0] }
            for _ in 0..<(((quarterTurns % 4) + 4) % 4) {
                // Clockwise: the new (row, column) comes from (2 - column, row).
                var next = grid
                for row in 0..<3 {
                    for column in 0..<3 {
                        next[row * 3 + column] = grid[(2 - column) * 3 + row]
                    }
                }
                grid = next
            }
            for offset in 0..<9 { turned[face.rawValue * 9 + offset] = grid[offset] }
        }
        return turned
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
