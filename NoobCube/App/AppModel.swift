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

        // The one line that makes a crash reproducible. A solve depends only on
        // the cube it started from, so with this in the console any failure can
        // be replayed exactly — in a test, or through the Python reference with
        // `Tools/replay.py`.
        print("NoobCube cube: \(state.facelets.map(\.letter).joined())")

        do {
            // A re-scan part way through is just a fresh plan from where the
            // cube actually is. Stages already finished come back empty, so the
            // child is never sent back over work they have done.
            let plan = try BeginnerSolver.solve(state, whiteFace: whiteFace)
            session = SolveSession(plan: plan, scan: finishedScan,
                                   scene: scene, narrator: narrator)
            session?.onLost = { [weak self] in self?.replanFromSmartCube() }

            // A smart cube knows which way it has been turned but not which
            // way up it is being held, so the scan is what lines the two up.
            // After this it can follow along by itself and nothing else in the
            // solve needs confirming.
            if smartCube.isConnected {
                announceAlignment(smartCube.align(toScan: state))
            }
            session?.cubeIsFollowing = smartCube.isFollowing
            screen = .ready
        } catch {
            errorMessage = error.localizedDescription
            narrator.say("I couldn't work that cube out. Let's look at it again.")
            screen = .scanning
        }
    }

    func beginSolving() {
        scene.clearHighlight()
        session?.cubeIsFollowing = smartCube.isFollowing
        screen = .solving
        // The cube may have been turned between the picture and pressing the
        // button. Better to notice here than to let the first real turn be
        // called wrong when it was the plan that had gone stale.
        if smartCube.isFollowing, let session, cubeHasMovedOn(from: session) {
            replanFromSmartCube()
        }
        session?.startStage()
    }

    /// Whether the cube is somewhere other than where the plan expects it.
    ///
    /// Compared as colours rather than as solver letters, because that is what
    /// both sides can be said in without another conversion that could throw.
    private func cubeHasMovedOn(from session: SolveSession) -> Bool {
        guard let cubeState = smartCube.cubeState, let alignment = smartCube.alignment else {
            return false
        }
        let asHeld = alignment.regripped(by: session.wholeCubeTurnsSoFar)
        let onTheCube = asHeld.appState(of: cubeState).facelets
            .map { CubeColour.defaultColour(for: $0) as CubeColour? }
        return onTheCube != session.displayCube.colours
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

    private func handleSmartCubeTurn(_ cubeMove: Move) {
        guard screen == .solving, let session, smartCube.isFollowing else { return }
        session.cubeIsFollowing = true

        // The cube names its own faces. Whichever of them is on the right is
        // what it calls R, and that need not be the side the child is being
        // told is the right. Every whole-cube turn the plan has asked for since
        // the scan moved the child's frame and left the cube's where it was, so
        // the grip is caught up from the plan rather than tallied as it goes.
        guard let base = smartCube.alignment else { return }

        // A cube cannot feel itself being turned round in your hands, so that
        // one instruction still offers a tap. But turning a layer at all is the
        // child saying they have moved on, so it dismisses the instruction
        // rather than being called a mistake — they plainly did turn it, or
        // they would not be turning layers.
        //
        // Which means the turn has to be read in the frame they are holding it
        // in *now*, with the rotation counted, not the one before it.
        let spins = session.pendingWholeCubeTurns
        let here = base.regripped(by: session.wholeCubeTurnsSoFar + spins)
        guard let move = here.appMove(for: cubeMove) else { return }

        if spins.isEmpty {
            session.handleSmartCubeTurn(move)
        } else {
            session.takeTheTurnAsDone(andThen: move)
        }
    }

    /// Work the plan out afresh from the cube's own position.
    func replanFromSmartCube() {
        guard let session, let cubeState = smartCube.cubeState else { return }
        // Said the way the child is holding it, not the way the cube thinks of
        // itself, so the plan talks about the faces they can actually see.
        let alignment = (smartCube.alignment ?? .identity)
            .regripped(by: session.wholeCubeTurnsSoFar)
        let state = alignment.appState(of: cubeState)
        let scanned = ScannedCube(colours: state.facelets.map { CubeColour.defaultColour(for: $0) })
        let whiteFace = scanned.face(withCentre: .white) ?? .D
        do {
            let plan = try BeginnerSolver.solve(state, whiteFace: whiteFace)
            scan = scanned
            // The cube is where it is, so the grip the plan starts from is the
            // one it has now; anything the old plan had turned is history.
            smartCube.reground(to: alignment)
            session.replacePlan(plan, scan: scanned)
            session.cubeIsFollowing = smartCube.isFollowing
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Say out loud how the cube and the scan got on, because a cube that
    /// cannot be lined up is the one thing the child would otherwise only
    /// discover by being told they are wrong over and over.
    private func announceAlignment(_ match: CubeAlignment.Match?) {
        switch match {
        case .found, .tooSymmetricToTell:
            narrator.say("Your cube is connected, so I can feel every turn you make.")
        case .cubeDisagrees:
            narrator.say("Your cube and the picture don\u{2019}t agree, so I\u{2019}ll "
                         + "wait for you to tell me each move.")
        case nil:
            narrator.say("Your cube hasn\u{2019}t told me where it is yet, so I\u{2019}ll "
                         + "wait for you to tell me each move.")
        }
    }

    /// The child says the cube is solved right now: the way back when the
    /// cube's own idea of itself has drifted from the cube in their hands.
    func smartCubeIsSolved() {
        smartCube.startFromSolved()
    }

    /// Begin a solve from wherever the connected cube says it is.
    ///
    /// Nothing is confirmed first. The cube says what it looks like the moment
    /// it connects, so the app shows that and gets on with it — the frame it
    /// reports in becomes the frame the child is told about, which is true
    /// enough to solve from and is put right the moment the camera looks.
    func startFromSmartCube() {
        guard let state = smartCube.cubeState else { return }
        let scanned = ScannedCube(colours: state.facelets.map { CubeColour.defaultColour(for: $0) })
        let whiteFace = scanned.face(withCentre: .white) ?? .D
        do {
            let plan = try BeginnerSolver.solve(state, whiteFace: whiteFace)
            smartCube.reground(to: .identity)
            scan = scanned
            session = SolveSession(plan: plan, scan: scanned, scene: scene, narrator: narrator)
            session?.onLost = { [weak self] in self?.replanFromSmartCube() }
            session?.cubeIsFollowing = smartCube.isFollowing
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
