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
    private var smartCubeGripObserver: AnyCancellable?
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
    /// The cube has been turned round in the child's hands.
    ///
    /// This used to be the one instruction a connected cube could not follow
    /// along with, because a cube cannot feel itself being turned — so it was
    /// the one that still asked for a tap. Its motion sensor can feel it
    /// perfectly well, so when the plan asks them to turn the cube round and
    /// they do, that is the end of it. No button.
    private func heldDifferently(_ held: CubeAlignment) {
        guard screen == .solving, let session else {
            gripWhenTheStepBegan = held
            return
        }
        // Not waiting on a turn of the whole cube, so whatever they have just
        // done with their hands is simply how they are holding it now.
        guard let asked = session.currentMove, asked.isWholeCubeTurn,
              let before = gripWhenTheStepBegan else {
            gripWhenTheStepBegan = held
            return
        }

        // The way the plan is asking them to hold it, measured from the way
        // they were holding it when the instruction came up.
        let wanted = before.regripped(by: session.pendingWholeCubeTurns)
        guard wanted.appFace == held.appFace else { return }
        gripWhenTheStepBegan = held
        session.confirmWholeCubeTurn()
    }

    /// How the cube was being held when the current instruction came up, which
    /// is what a "turn it round" is measured against.
    private var gripWhenTheStepBegan: CubeAlignment?

    private func observeSmartCube() {
        // The move, not the message. What the cube calls its faces is the
        // cube's business and ``SmartCubeDialect``'s; by the time it reaches
        // here it is a turn in the cube's own frame.
        smartCubeObserver = smartCube.$lastMove
            .compactMap { $0 }
            .sink { [weak self] move in
                Task { @MainActor in self?.handleSmartCubeTurn(move) }
            }
        smartCubeGripObserver = smartCube.$sensorGrip
            .compactMap { $0 }
            .sink { [weak self] held in
                Task { @MainActor in self?.heldDifferently(held) }
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
            // wrong thing on no evidence at all — but the cube has moved, and
            // the screen has not, so from here the two are out of step until
            // the grip settles and the screen can be put right from the cube.
            screenIsBehindTheCube = true
            narrator.say("I\u{2019}m still learning how you\u{2019}re holding your cube. "
                         + "Have a go at the move I asked for.")
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
                screenIsBehindTheCube = true
                narrator.say("Sorry — I was looking at your cube the wrong way "
                             + "round. Keep going and I\u{2019}ll catch up.")
                return
            }
        }

        let reading = fitting.first.map { here[$0] } ?? here[0]
        guard let move = reading.appMove(for: cubeMove) else { return }
        smartCube.noteTurn(cubeMove, readAs: move)

        // The grip has just come down to one and the screen missed some turns
        // while it was being worked out. The cube knows where it is, so the
        // screen is put right from it rather than left quietly wrong.
        if screenIsBehindTheCube, !smartCube.isStillWorkingOutTheGrip {
            screenIsBehindTheCube = false
            narrator.say("Got it — that\u{2019}s how you\u{2019}re holding it.")
            return catchUpWithTheCube()
        }

        if spins.isEmpty {
            session.handleSmartCubeTurn(move)
        } else {
            session.takeTheTurnAsDone(andThen: move)
        }
    }

    /// The screen has fallen behind the cube in the child's hands.
    ///
    /// Only ever true while the grip is being worked out, because a turn that
    /// cannot be named cannot be drawn. The cube itself never loses track, so
    /// catching up is a matter of asking it where it is.
    private var screenIsBehindTheCube = false

    private func catchUpWithTheCube() {
        replanFromSmartCube()
    }

    /// Work the plan out afresh from the cube's own position.
    ///
    /// Only possible once the grip is known *and* the cube's own position has
    /// been put right by a scan. Either missing, and the camera is the way back
    /// rather than a guess — planning a solve from a position the cube has got
    /// wrong is how a correct scan ends up replaced by a wrong one.
    func replanFromSmartCube() {
        guard let session, let cubeState = smartCube.cubeState else { return }

        // A cube that is still telling us its turns is not lost, whatever it
        // has just done. If the grip is not settled yet, the next turn or two
        // will settle it and the screen is put right then — sending a child
        // back to the camera because they fumbled two turns in a row is the
        // app giving up on a cube that is working perfectly well.
        guard smartCube.alignment != nil, smartCube.positionIsTrustworthy else {
            guard smartCube.isFollowing else {
                narrator.say("Let me look at your cube again.")
                rescan()
                return
            }
            screenIsBehindTheCube = true
            narrator.say("Let me work out how you\u{2019}re holding it. "
                         + "Carry on turning.")
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
    /// it connects, so the app shows that and gets on with it.
    ///
    /// The plan is written in the cube's own frame, which is the only frame
    /// available before the camera has looked. That does *not* mean the child
    /// is holding it that way. The app used to say it did — a flat assertion
    /// that the grip was the identity one — and being a single settled grip it
    /// stopped the app ever learning otherwise: a child turning the side the
    /// screen showed them was told, over and over, that they had turned the
    /// wrong one. It is a one-in-twenty-four guess, so it is right about four
    /// times in a hundred.
    ///
    /// So the grip is left open instead, and the first turn or two settle it —
    /// measured at a median of two turns in `Tools/CubeReference/alignment.py`,
    /// three at worst, and every turn in the meantime is read correctly anyway
    /// because all the surviving ways of holding it agree on what it was.
    func startFromSmartCube() {
        guard let state = smartCube.cubeState else { return }
        let scanned = ScannedCube(colours: state.facelets.map { CubeColour.defaultColour(for: $0) })
        let whiteFace = scanned.face(withCentre: .white) ?? .D
        do {
            let plan = try BeginnerSolver.solve(state, whiteFace: whiteFace)
            smartCube.openEveryGrip(trustingPosition: true)
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
