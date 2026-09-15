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
             title: "Show me the front",
             spoken: "Hold your cube with the white side on the bottom and yellow on top. Now show me the front."),
        Step(face: .R,
             title: "Spin it left",
             spoken: "Great. Now spin the whole cube to the left, and show me the new front."),
        Step(face: .B,
             title: "Spin it left again",
             spoken: "Spin it to the left again."),
        Step(face: .L,
             title: "And again",
             spoken: "One more spin to the left."),
        Step(face: .U,
             title: "Show me the top",
             spoken: "Now spin it left once more to get back to the start, then tip it forwards so I can see the yellow top."),
        Step(face: .D,
             title: "Show me the bottom",
             spoken: "Last one. Tip it back twice so I can see the white bottom."),
    ]

    @Published private(set) var scan = ScannedCube()
    @Published private(set) var stepIndex = 0
    @Published private(set) var isComplete = false
    @Published private(set) var problem: String?
    /// Set once the cube has been read and checked.
    @Published private(set) var result: (state: CubeState, whiteFace: Face)?

    /// Raw camera readings, kept so the whole scan can be settled at the end.
    private var rawSamples = [RGBSample?](repeating: nil, count: 54)
    private var holdFrames = 0

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

    /// The colours under the guide right now, for the nine live squares.
    var livePreview: [CubeColour] {
        guard camera.liveSamples.count == 9 else { return [] }
        return ColourClassifier.bestGuesses(camera.liveSamples)
    }

    // MARK: - Running the scan

    func begin() {
        scan = ScannedCube()
        rawSamples = [RGBSample?](repeating: nil, count: 54)
        stepIndex = 0
        isComplete = false
        problem = nil
        result = nil
        holdFrames = 0
        camera.start()
        camera.resetSteadiness()
        announceStep()
    }

    func announceStep() {
        guard let step = currentStep else { return }
        narrator.say(step.spoken)
    }

    func stop() {
        camera.stop()
    }

    /// Called every frame: take the face automatically once the cube is held still.
    func considerAutoCapture() {
        guard currentStep != nil, !isComplete else { return }
        if camera.steadiness > 0.88 {
            holdFrames += 1
            if holdFrames >= 6 {
                captureCurrentFace()
            }
        } else {
            holdFrames = 0
        }
    }

    /// Record the face the camera is looking at now.
    func captureCurrentFace() {
        guard let step = currentStep, camera.liveSamples.count == 9 else { return }
        store(samples: camera.liveSamples, on: step.face)
        holdFrames = 0
        camera.resetSteadiness()

        if stepIndex + 1 < Self.steps.count {
            stepIndex += 1
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
        scan.setFace(face, to: ColourClassifier.bestGuesses(samples))
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
            announceStep()
        }
    }

    // MARK: - Settling the scan

    private func finish() {
        guard let samples = completeSamples() else {
            problem = "Some squares weren't seen. Let's go round again."
            return
        }

        let settled = ColourClassifier.resolve(rawSamples: samples)
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
