import Combine
import SwiftUI

/// Which screen is up, and everything shared between them.
@MainActor
final class AppModel: ObservableObject {

    enum Screen: Hashable {
        case welcome
        case scanning
        case ready
        case solving
    }

    @Published private(set) var screen: Screen = .welcome
    @Published private(set) var session: SolveSession?
    @Published private(set) var scan: ScannedCube?
    @Published var errorMessage: String?

    let narrator = Narrator()
    let scene = CubeSceneController()
    let camera = CameraController()
    let smartCube: SmartCubeManager
    private(set) lazy var scanCoordinator = ScanCoordinator(camera: camera, narrator: narrator)

    private var smartCubeObserver: AnyCancellable?
    private var smartCubeStatusObserver: AnyCancellable?

    init() {
        smartCube = SmartCubeManager()
        scene.setColours(ScannedCube.solvedColours)
        observeSmartCube()
        // The welcome screen shows the cube's connection state, so its changes
        // have to reach views observing this model.
        smartCubeStatusObserver = smartCube.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    // MARK: - Moving between screens

    func showWelcome() {
        screen = .welcome
        scene.reset(to: scan?.colours ?? ScannedCube.solvedColours)
        scene.startIdleSpin()
    }

    func startScanning() {
        scene.stopIdleSpin()
        screen = .scanning
    }

    /// The camera finished and the child confirmed the colours.
    func scanFinished(state: CubeState, whiteFace: Face, scan finishedScan: ScannedCube) {
        scan = finishedScan
        camera.stop()
        do {
            // A re-scan part way through is just a fresh plan from where the
            // cube actually is. Stages already finished come back empty, so the
            // child is never sent back over work they have done.
            let plan = try BeginnerSolver.solve(state, whiteFace: whiteFace)
            session = SolveSession(plan: plan, scan: finishedScan,
                                   scene: scene, narrator: narrator)

            // A smart cube knows which way it has been turned but not what
            // colour anything is, so the scan is what tells it where it is
            // starting from. After this it can follow along by itself.
            if smartCube.isConnected {
                smartCube.calibrate(to: state)
            }
            screen = .ready
        } catch {
            errorMessage = error.localizedDescription
            narrator.say("I couldn't work that cube out. Let's look at it again.")
            screen = .scanning
        }
    }

    func beginSolving() {
        scene.clearHighlight()
        screen = .solving
        session?.startStage()
    }

    /// The child wants the app to look at the cube again, part way through.
    func rescan() {
        scene.stopIdleSpin()
        narrator.say("Let's have another look at your cube.")
        screen = .scanning
    }

    func finishSolve() {
        session = nil
        scan = nil
        showWelcome()
    }

    // MARK: - Smart cube

    /// Follow a connected cube: matching turns move the child along, and any
    /// other turn means the cube is no longer where we thought, so the plan is
    /// worked out again from what the cube says it is.
    private func observeSmartCube() {
        smartCubeObserver = smartCube.$lastTurn
            .compactMap { $0 }
            .sink { [weak self] turn in
                Task { @MainActor in self?.handleSmartCubeTurn(turn.move) }
            }
    }

    private func handleSmartCubeTurn(_ move: Move) {
        guard screen == .solving, let session else { return }
        if session.handleSmartCubeTurn(move) { return }
        replanFromSmartCube()
    }

    /// Re-plan from the cube's own tracked state.
    func replanFromSmartCube() {
        guard let state = smartCube.trackedState, let session else { return }
        let colours = smartCube.trackedColours ?? ScannedCube.solvedColours
        let scanned = ScannedCube(colours: colours)
        let whiteFace = scanned.face(withCentre: .white) ?? .D
        do {
            let plan = try BeginnerSolver.solve(state, whiteFace: whiteFace)
            scan = scanned
            session.replacePlan(plan, scan: scanned)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The child says the cube is solved right now, so the app can start
    /// following it without the camera.
    ///
    /// This is the one position a smart cube can be told about without looking
    /// at it: from here every turn it reports keeps the app in step, so the
    /// child can scramble it and be walked back.
    func smartCubeIsSolved() {
        smartCube.calibrate(to: .solved)
    }

    /// Begin a solve from wherever the connected cube has been turned to.
    func startFromSmartCube() {
        guard smartCube.isCalibrated, let state = smartCube.trackedState else { return }
        let colours = smartCube.trackedColours ?? ScannedCube.solvedColours
        let scanned = ScannedCube(colours: colours)
        let whiteFace = scanned.face(withCentre: .white) ?? .D
        do {
            let plan = try BeginnerSolver.solve(state, whiteFace: whiteFace)
            scan = scanned
            session = SolveSession(plan: plan, scan: scanned, scene: scene, narrator: narrator)
            scene.stopIdleSpin()
            screen = .ready
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

extension ScannedCube {
    /// A solved cube in the usual colours, for the idle screens.
    static var solvedColours: [CubeColour?] {
        CubeState.solved.facelets.map { CubeColour.defaultColour(for: $0) }
    }
}
