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

    /// Turns in a row that fitted no way of holding the cube. A child fumbling
    /// gets some right; a wrong grip gets everything wrong, so a run of them is
    /// evidence about the grip rather than about the child.
    private var turnsThatFittedNothing = 0

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
            session?.onSolved = { [weak self] in self?.smartCubeIsSolved() }

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
        // The move, not the message. What the cube calls its faces is the
        // cube's business and ``SmartCubeDialect``'s; by the time it reaches
        // here it is a turn in the cube's own frame.
        smartCubeObserver = smartCube.$lastMove
            .compactMap { $0 }
            .sink { [weak self] move in
                Task { @MainActor in self?.handleSmartCubeTurn(move) }
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
        // A cube cannot feel itself being turned round in your hands, so that
        // one instruction still offers a tap. But turning a layer at all is the
        // child saying they have moved on, so it dismisses the instruction
        // rather than being called a mistake — they plainly did turn it, or
        // they would not be turning layers.
        //
        // Which means the turn has to be read in the frame they are holding it
        // in *now*, with the rotation counted, not the one before it.
        let spins = session.pendingWholeCubeTurns
        let spinsSoFar = session.wholeCubeTurnsSoFar + spins
        let here = smartCube.grips.map { $0.regripped(by: spinsSoFar) }
        guard !here.isEmpty else { return }

        // The move we asked for is what narrows an unknown grip: only the ways
        // of holding the cube that make this turn *be* that move survive. They
        // all agree on what the turn was — that is what put them in the set —
        // so it can be acted on now, while the grip is still coming down.
        let asked = spins.isEmpty ? session.currentMove : session.moveAfterWholeCubeTurns
        let fitting = asked.map { want in
            here.indices.filter { here[$0].appMove(for: cubeMove) == want }
        } ?? []

        if !fitting.isEmpty {
            smartCube.narrow(to: fitting.map { smartCube.grips[$0] })
            turnsThatFittedNothing = 0

        } else if smartCube.isStillWorkingOutTheGrip {
            // Nothing fits and the grip is not known well enough to say what
            // they turned. Guessing would mean telling a child they turned the
            // wrong thing on no evidence at all.
            narrator.say("I\u{2019}m still working out which way round your cube is. "
                         + "Try the move I asked for.")
            return

        } else {
            // The grip is settled and yet nothing the child does fits it. One
            // of those is a mistake. Three in a row is the grip being wrong —
            // a child fumbling gets some of them right, and a grip is only ever
            // as good as the position it was worked out from. So it is thrown
            // away and learned again from the turns, which are better evidence
            // than the cube's own idea of where it is.
            turnsThatFittedNothing += 1
            if turnsThatFittedNothing >= 3 {
                turnsThatFittedNothing = 0
                smartCube.reopenTheGrip()
                session.forgetTheMistake()
                narrator.say("I had which way round your cube is wrong. "
                             + "Do the next move and I\u{2019}ll pick it up.")
                return
            }
        }

        let reading = fitting.first.map { here[$0] } ?? here[0]
        guard let move = reading.appMove(for: cubeMove) else { return }
        smartCube.noteTurn(cubeMove, readAs: move)

        if spins.isEmpty {
            session.handleSmartCubeTurn(move)
        } else {
            session.takeTheTurnAsDone(andThen: move)
        }
    }

    /// Work the plan out afresh from the cube's own position.
    ///
    /// Only possible once the grip is known *and* the cube's own position has
    /// been put right by a scan. Either missing, and the camera is the way back
    /// rather than a guess — planning a solve from a position the cube has got
    /// wrong is how a correct scan ends up replaced by a wrong one.
    func replanFromSmartCube() {
        guard let session, let cubeState = smartCube.cubeState else { return }
        guard smartCube.alignment != nil, smartCube.positionIsTrustworthy else {
            narrator.say("Let me look at your cube again.")
            rescan()
            return
        }
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

    /// The cube is solved — either because the child said so, or because the
    /// solve just finished and it demonstrably is.
    ///
    /// This is the one position a cube can be told about without looking at it,
    /// so finishing a solve is a free chance to put its own idea of itself
    /// straight. Whatever drift had crept in is gone, and the next scramble is
    /// tracked from a position both sides agree on.
    func smartCubeIsSolved() {
        guard smartCube.isConnected else { return }
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
            session?.onSolved = { [weak self] in self?.smartCubeIsSolved() }
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
