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
        guard camera.liveSamples.count == 9 else { return [] }
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
        guard camera.steadiness > 0.88, camera.settling >= 1 else {
            holdFrames = 0
            return
        }
        // Holding the cube still is not a reason to take the same side twice.
        guard hasMovedOn(to: camera.steadyReading) else {
            holdFrames = 0
            return
        }
        holdFrames += 1
        if holdFrames >= 8 {
            captureCurrentFace()
        }
    }

    /// Whether the camera is looking at something other than the side already
    /// taken. A cube turned to a new side changes far more than a hand shaking.
    private func hasMovedOn(to reading: [RGBSample]) -> Bool {
        guard lastCaptured.count == 9, reading.count == 9 else { return true }
        var difference = 0.0
        for index in 0..<9 {
            difference += abs(reading[index].red - lastCaptured[index].red)
                + abs(reading[index].green - lastCaptured[index].green)
                + abs(reading[index].blue - lastCaptured[index].blue)
        }
        return difference / 27 > 0.07
    }

    /// Record the side the camera is looking at.
    ///
    /// Which side it is filed as comes from the colour of its middle sticker,
    /// so showing the sides in the wrong order simply works. But only while
    /// that colour names a side we have not already seen: a middle sticker read
    /// wrongly used to file the new side on top of a good one, quietly undoing
    /// earlier work, and then the app asked for the missing side again — and
    /// again, because it was never going to arrive. When the colour names a
    /// side already done, the side being asked for is the better answer.
    func captureCurrentFace() {
        let reading = camera.steadyReading.count == 9 ? camera.steadyReading : camera.liveSamples
        guard let step = currentStep, reading.count == 9 else { return }

        // The button is there to hurry the app along, not to take the same side
        // a second time. Say what is actually needed instead.
        guard hasMovedOn(to: reading) else {
            narrator.say("I've got that side already. Turn the cube to the next one.")
            return
        }

        let guesses = ColourClassifier.bestGuesses(relit(reading))
        let named = CubeColourScheme.face(forCentre: guesses[4])
        let face = (named.map { !scan.isFaceScanned($0) } ?? false) ? named! : step.face

        store(samples: reading, on: face)
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
        scan.setFace(face, to: ColourClassifier.bestGuesses(corrected))
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
        let settled = ColourClassifier.resolve(rawSamples: samples, expectedCentres: expected)
        var candidate = ScannedCube(colours: settled.map { Optional($0) })

        // The top and bottom are the awkward ones to hold square to the camera,
        // so try them every way round and keep whichever makes a real cube.
        if let fixed = bestOrientation(for: candidate) {
            candidate = fixed
        }

        scan = candidate
        isComplete = true

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

    /// Try the top and bottom at all four rotations, keep a combination that
    /// makes a solvable cube.
    private func bestOrientation(for candidate: ScannedCube) -> ScannedCube? {
        var firstValid: ScannedCube?
        for topTurns in 0..<4 {
            for bottomTurns in 0..<4 {
                var trial = candidate
                trial.rotateFaceStickers(.U, quarterTurns: topTurns)
                trial.rotateFaceStickers(.D, quarterTurns: bottomTurns)
                guard let converted = try? trial.cubeState() else { continue }
                if converted.state.isValid {
                    // The child was probably holding it as asked, so an
                    // unrotated fit wins outright.
                    if topTurns == 0 && bottomTurns == 0 { return trial }
                    if firstValid == nil { firstValid = trial }
                }
            }
        }
        return firstValid
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
