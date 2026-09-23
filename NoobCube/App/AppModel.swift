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
            let fresh = SolveSession(plan: plan, scan: finishedScan,
                                     scene: scene, narrator: narrator)
            follow(fresh)
            session = fresh
            smartCube.logMoment("new plan from the camera, \(plan.moveCount) moves",
                                why: "the camera looked at the cube")

            // The camera has just seen which colour is on which side. A cube's
            // middles never move, so that is all it takes to know where the
            // cube's own faces have got to — no searching, no learning, and it
            // does not matter how the child is holding it.
            if smartCube.isConnected {
                announceAlignment(smartCube.align(toScan: state,
                                                  middles: finishedScan.centres))
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
        smartCube.logMoment("started solving", why: "they pressed the button")
        scene.clearHighlight()
        session?.cubeIsFollowing = smartCube.isFollowing
        screen = .solving
        session?.startStage(because: "the solve began")
    }

    /// The child wants the app to look at the cube again, part way through.
    func rescan() {
        smartCube.logMoment("back to the camera", why: "the app asked for another look")
        scene.stopIdleSpin()
        narrator.say("Let's have another look at your cube.")
        screen = .scanning
    }

    func finishSolve() {
        smartCube.logMoment("back to the start", why: "they left the solve")
        session = nil
        scan = nil
        showWelcome()
    }

    /// Hook a freshly made session up to everything that watches it.
    ///
    /// One place, because a session made in one screen and a session made in
    /// another were drifting apart: the move log was wired to one of them.
    private func follow(_ session: SolveSession) {
        session.onLost = { [weak self] in self?.replanFromSmartCube() }
        session.onSolved = { [weak self] in self?.smartCubeIsSolved() }
        session.logMoment = { [weak self] what, why in
            self?.smartCube.logMoment(what, why: why)
        }
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
        smartCube.onTurn = { [weak self] move in self?.handleSmartCubeTurn(move) }
        smartCubeGripObserver = smartCube.$sensorGrip
            .compactMap { $0 }
            .sink { [weak self] held in
                Task { @MainActor in self?.heldDifferently(held) }
            }
    }

    private func handleSmartCubeTurn(_ cubeMove: Move) {
        guard screen == .solving, let session, smartCube.isFollowing else {
            smartCube.logReading(nil, asked: nil,
                                 outcome: screen == .solving
                                 ? "ignored: the cube is not being followed"
                                 : "ignored: not on the solving screen")
            return
        }
        session.cubeIsFollowing = true

        // Which side of the screen just turned, read straight off the colours.
        //
        // The cube says exactly which of its own faces moved and which way.
        // That face is a colour — the one it calls R is its red one, welded
        // into the plastic — and the picture on screen has that colour on one
        // of its sides. So the translation is a lookup, and how the child
        // happens to be holding the cube never comes into it.
        //
        // There used to be twenty-four candidate ways of holding it here,
        // narrowed by whether a turn matched the move being asked for, thrown
        // away after three that did not, with turns swallowed in the meantime
        // and the screen left to catch up. Every one of those paths showed up
        // in the first move log taken, and not one of them was answering a
        // question the cube had not already answered.
        //
        // Measured against the picture as it will be once the whole-cube turns
        // the plan is waiting on have been played, because the move being
        // asked for is written in that frame. A face turn moves no middles, so
        // nothing else here can change the answer.
        let spins = session.pendingWholeCubeTurns
        let picture = spins.isEmpty ? session.displayCube
                                    : session.displayCube.applying(spins)
        smartCube.lineUp(withPictureShowing: picture.centres)

        let asked = spins.isEmpty ? session.currentMove : session.moveAfterWholeCubeTurns
        guard let move = smartCube.alignment.appMove(for: cubeMove) else {
            smartCube.logReading(nil, asked: asked,
                                 outcome: "ignored: \(cubeMove.notation) is not a face turn")
            return
        }
        smartCube.noteTurn(cubeMove, readAs: move, whenAskedFor: asked)

        if spins.isEmpty {
            session.handleSmartCubeTurn(move)
        } else {
            session.takeTheTurnAsDone(andThen: move)
        }
        smartCube.logReading(move, asked: asked, outcome: session.lastReaction)
    }

    /// The child has said which colour side they just turned.
    ///
    /// The one fact the app cannot get for itself, and the one that tells the
    /// three suspects apart: the number the cube sent, what the app made of it,
    /// and what it asked for. Taken together in ``TurnLog`` they name the
    /// culprit rather than describing the symptom.
    func theyTurnedByHand(_ colour: CubeColour) {
        // Read live, not from the scan: a whole-cube turn moves every colour to
        // a different side of the picture without the plan changing at all.
        if let session { smartCube.picture(session.displayCube.centres) }
        smartCube.theyTurned(colour)
    }

    /// Work the plan out afresh from the cube's own position.
    ///
    /// Never a dead end. A cube's face numbers are welded to its plastic, so
    /// the position it reports is right whatever else has gone on, and a plan
    /// can always be built from it. The camera is only for a cube that has
    /// stopped talking altogether.
    func replanFromSmartCube() {
        guard let session, let cubeState = smartCube.cubeState else { return }
        guard smartCube.isFollowing else {
            narrator.say("Let me look at your cube again.")
            rescan()
            return
        }

        // The picture as it stands is what the cube's faces are named against,
        // so that is what the new plan is written in. Nothing is counted or
        // composed: a whole-cube turn the old plan asked for is already in the
        // picture, because the app is what turned it.
        let held = CubeAlignment.matching(centresSeen: session.displayCube.centres)
            ?? smartCube.alignment
        let state = held.appState(of: cubeState)
        let scanned = ScannedCube(colours: state.facelets.map { CubeColour.defaultColour(for: $0) })
        let whiteFace = scanned.face(withCentre: .white) ?? .D
        do {
            let plan = try BeginnerSolver.solve(state, whiteFace: whiteFace)
            scan = scanned
            session.replacePlan(plan, scan: scanned,
                                because: "worked out again from where the cube says it is, "
                                + "reading turns against \(smartCube.heldInWords)")
            // The picture has just been redrawn, so what to call each of the
            // cube's faces is read off it again.
            smartCube.lineUp(withPictureShowing: scanned.centres)
            session.cubeIsFollowing = smartCube.isFollowing
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Say whether the cube can be followed, and nothing more.
    ///
    /// The one case worth mentioning is a cube that has not said where it is
    /// at all, because then there is nothing to follow. Everything else is the
    /// app's own business: the cube reports every turn absolutely, and what to
    /// call each face is read off the colours on screen.
    private func announceAlignment(_ lined: Bool) {
        guard lined else {
            narrator.say("Your cube hasn\u{2019}t told me where it is yet, so I\u{2019}ll "
                         + "wait for you to tell me each move.")
            return
        }
        narrator.say("Your cube is connected, so I can feel every turn you make.")
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
        // The cube described itself in its own frame — white on top, the way it
        // numbers its faces. The child is asked to hold theirs yellow on top,
        // so the plan and the picture are said that way round instead, and the
        // half turn between the two is exactly what "it turns the opposite
        // side" was.
        // Whatever the last picture said, if there was one. A cube only has to
        // be pictured once: its middles never move, so the colours from that
        // picture still hold, and the cube supplies where its pieces are now.
        let held = smartCube.alignment
        let asTheyHoldIt = held.appState(of: state)
        let scanned = ScannedCube(
            colours: asTheyHoldIt.facelets.map { CubeColour.defaultColour(for: $0) })
        let whiteFace = scanned.face(withCentre: .white) ?? .D
        do {
            let plan = try BeginnerSolver.solve(asTheyHoldIt, whiteFace: whiteFace)
            scan = scanned
            smartCube.lineUp(withPictureShowing: scanned.centres)
            let fresh = SolveSession(plan: plan, scan: scanned, scene: scene, narrator: narrator)
            follow(fresh)
            session = fresh
            smartCube.logMoment("new plan from the cube itself, \(plan.moveCount) moves",
                                why: "holding it \(smartCube.heldInWords)")
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
