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
    /// Something went wrong that the child has to be told about. Shown in a
    /// box with one button — and said, because a box of words is nothing to
    /// someone who cannot read it.
    @Published var errorMessage: String? {
        didSet {
            guard let errorMessage, errorMessage != oldValue else { return }
            narrator.say("\(errorMessage) Press the button to carry on.")
        }
    }

    let narrator = Narrator()
    /// "Next" and "back", said instead of pressed.
    let voice = VoiceCommands()
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
        listenForCommands()
    }

    // MARK: - Saying "next"

    private func listenForCommands() {
        voice.isOwnVoice = { [weak self] command in
            self?.narrator.mightHaveJustSaid(anyOf: command.spellings) ?? false
        }
        voice.onCommand = { [weak self] command, word in
            guard let self, self.screen == .solving, let session = self.session else { return false }
            let did = session.heard(command)
            self.smartCube.logMoment("heard \"\(word)\"",
                                     why: did ? "said instead of pressed" : "nothing to do with it just then")
            return did
        }
    }

    /// The microphone button on the solve screen.
    func toggleListening() {
        Task { @MainActor in
            let wasOn = voice.isWanted
            if !wasOn, voice.needsToAsk {
                narrator.say("I need to ask if I can listen. Ask a grown-up to press Allow.")
            }
            await voice.toggle()
            session?.isListening = voice.state == .listening
            switch voice.state {
            case .listening:
                narrator.explain([.init("I'm listening. When you've done a move, say next. "
                                        + "To go back one, say back.",
                                        pointingAt: .headerMicrophone)])
            case .notAllowed:
                narrator.say("I'm not allowed to listen. A grown-up can turn on the microphone "
                             + "and speech recognition for NoobCube in Settings.")
            case .unavailable:
                narrator.say("Listening doesn't work on this phone, so press the buttons instead.")
            case .off:
                if wasOn { narrator.say("I've stopped listening.") }
            }
        }
    }

    /// Listening only while the solve screen is up and the app is in front.
    func solveScreenIsShowing(_ showing: Bool) {
        Task { @MainActor in
            await voice.screenIsShowing(showing)
            session?.isListening = voice.state == .listening
        }
    }

    // MARK: - Moving between screens

    func showWelcome() {
        screen = .welcome
        // A solve waiting to be carried on shows the cube as far as they got.
        let paused = pausedOn == nil ? nil : session?.displayCube.colours
        scene.reset(to: paused ?? scan?.colours ?? ScannedCube.solvedColours)
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
            let plan = try method.solve(state, whiteFace: whiteFace)
            let fresh = SolveSession(plan: plan, scan: finishedScan,
                                     scene: scene, narrator: narrator)
            follow(fresh)
            session = fresh
            pausedOn = nil
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
        // A cube can be turned on the screen before this one, where nothing is
        // following it; the picture starts from the cube, not from the plan.
        holdThePictureToTheCube()
    }

    /// The child wants the app to look at the cube again, part way through.
    func rescan() {
        smartCube.logMoment("back to the camera", why: "the app asked for another look")
        scene.stopIdleSpin()
        narrator.say("Let's have another look at your cube.")
        screen = .scanning
    }

    func finishSolve() {
        smartCube.logMoment("back to the start", why: "the solve was finished with")
        session = nil
        scan = nil
        pausedOn = nil
        showWelcome()
    }

    /// Say what the buttons on the home screen do, pointing at each.
    func explainTheHomeScreen() {
        var parts: [Narrator.Part] = [.init("Let's solve your cube together!")]
        if canCarryOn {
            parts.append(.init("To carry on where you left off, press the green play button.",
                               pointingAt: .carryOn))
            parts.append(.init("To start again with a new cube, press the camera button.",
                               pointingAt: .showMeYourCube))
        } else {
            parts.append(.init("To show me your cube, press the blue camera button.",
                               pointingAt: .showMeYourCube))
        }
        parts.append(.init(smartCube.isConnected
                           ? "To use your smart cube, press the button with the cube on it."
                           : "If you have a smart cube, press the button with the cube on it.",
                           pointingAt: .smartCube))
        parts.append(.init("We're solving it the \(method.title) way. To pick a different way, "
                           + "press one of the three buttons in a row.",
                           pointingAt: method.button))
        narrator.explain(parts)
    }

    /// "Solve it again", after solving with a smart cube.
    ///
    /// The cube says where it is, so there is nothing to show the camera and
    /// no reason to go home first. Still solved, it asks for a mix-up first
    /// rather than starting a solve with nothing in it.
    func solveAgain() {
        guard smartCube.isFollowing, let state = smartCube.cubeState else { return finishSolve() }
        guard !state.isSolved else {
            narrator.explain([
                .init("Mix your cube up first. Turn it lots of different ways."),
                .init("Then press the green button again.", pointingAt: .playAgain),
            ])
            return
        }
        smartCube.logMoment("solving again", why: "they mixed it up and asked to go again")
        // A fresh start the usual way round — green facing them, yellow on
        // top — rather than however the last solve left the picture turned.
        smartCube.lineUp(withPictureShowing: CubeAlignment.asTheChildIsAskedToHoldIt.pictureCentres)
        startFromSmartCube()
    }

    // MARK: - Going home part way

    /// Where they were when they went home part way through, so they can carry
    /// on from there. Nil when there is nothing to carry on with.
    @Published private(set) var pausedOn: Screen?

    // MARK: - How to solve it

    /// Beginner, Faster or Speedcuber: chosen on the home screen, and used for
    /// every cube from then on. Remembered between launches, unlike the mute —
    /// a child who has moved on to a faster way should not be sent back to the
    /// daisy every morning.
    @Published private(set) var method: SolveMethod = AppModel.savedMethod

    private static let methodKey = "NoobCube.method"

    private static var savedMethod: SolveMethod {
        UserDefaults.standard.string(forKey: methodKey).flatMap(SolveMethod.init(rawValue:)) ?? .beginner
    }

    func choose(_ chosen: SolveMethod) {
        narrator.explain([.init(chosen.spoken, pointingAt: chosen.button)])
        guard chosen != method else { return }
        method = chosen
        UserDefaults.standard.set(chosen.rawValue, forKey: Self.methodKey)
        smartCube.logMoment("solving the \(chosen.title) way", why: "they picked it on the home screen")
    }

    /// A plan the chosen way, from a cube as the picture shows it.
    private func planTheChosenWay(from picture: ScannedCube) -> SolvePlan? {
        guard let now = try? picture.cubeState() else { return nil }
        return try? method.solve(now.state, whiteFace: now.whiteFace)
    }

    /// Whether there is a solve to go back to.
    var canCarryOn: Bool { pausedOn != nil && session != nil }

    /// The house button. It used to throw the solve away, so a child who
    /// wandered off to the home screen had to show the camera their cube and
    /// start from the beginning. Now the solve waits for them.
    func goHome() {
        if let session, !session.isFinished, screen == .solving || screen == .ready {
            pausedOn = screen
            session.stopPlayingThrough()
            smartCube.logMoment("paused", why: "they went home part way through")
        }
        showWelcome()
    }

    /// Back to exactly where they were, next instruction and all.
    ///
    /// A connected cube may have been turned in the meantime, so the picture
    /// is held to the cube straight away and the plan follows it if it moved.
    func carryOn() {
        guard let paused = pausedOn, let session else { return }
        pausedOn = nil
        smartCube.logMoment("carried on", why: "they came back from the home screen")
        scene.stopIdleSpin()
        scene.reset(to: session.displayCube.colours)

        // They picked a different way while they were home: the rest of the
        // solve is worked out again that way, from where the cube is now.
        if session.plan.method != method, let plan = planTheChosenWay(from: session.displayCube) {
            smartCube.logMoment("new plan, the \(method.title) way, \(plan.moveCount) moves",
                                why: "they changed the way to solve it on the home screen")
            if paused == .ready {
                let fresh = SolveSession(plan: plan, scan: session.displayCube,
                                         scene: scene, narrator: narrator)
                follow(fresh)
                self.session = fresh
                fresh.cubeIsFollowing = smartCube.isFollowing
                screen = .ready
                return
            }
            screen = paused
            session.cubeIsFollowing = smartCube.isFollowing
            session.replacePlan(plan, scan: session.displayCube,
                                because: "they chose the \(method.title) way")
            holdThePictureToTheCube()
            return
        }
        screen = paused
        guard paused == .solving else { return }
        session.cubeIsFollowing = smartCube.isFollowing
        session.showWhereWeAre()
        holdThePictureToTheCube()
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
        session.onSettled = { [weak self] in self?.holdThePictureToTheCube() }
        session.isListening = voice.state == .listening
    }

    // MARK: - The picture is the cube

    /// The cube in the child's hands, drawn in the picture's colours.
    ///
    /// Read off the cube's own position rather than built up turn by turn:
    /// its face numbers are welded to its plastic, and each of its faces is a
    /// colour the picture has on one of its sides.
    private func theCubeAsItReallyIs(for session: SolveSession) -> ScannedCube? {
        guard let cubeState = smartCube.cubeState,
              let held = CubeAlignment.matching(centresSeen: session.displayCube.centres)
        else { return nil }
        return held.painted(cubeState)
    }

    /// Make sure the picture is the cube, and put it right if it is not.
    ///
    /// With a smart cube connected there is no excuse for the two ever
    /// differing: the cube says exactly where it is. But the picture is drawn a
    /// turn at a time, as animations, and anything that slips — a turn sent
    /// twice, a turn lost, a re-plan built at the wrong moment — used to stay
    /// in the picture for the rest of the solve, a jumble that no longer
    /// matched anything. So whenever everything has been drawn, the picture is
    /// checked against the cube, and the cube wins. The plan goes with it,
    /// because a plan worked out for the wrong cube is no use either.
    ///
    /// Then the cube is asked where it is, so the app's own copy is checked
    /// against the cube's word too — see ``SmartCubeManager/onPositionCorrected``.
    private func holdThePictureToTheCube(andAsk ask: Bool = true) {
        guard screen == .solving, let session, smartCube.isFollowing,
              !session.isBusy, let real = theCubeAsItReallyIs(for: session) else { return }
        if real != session.displayCube {
            let off = zip(real.colours, session.displayCube.colours).filter { $0 != $1 }.count
            smartCube.logMoment("the picture had drifted from the cube, \(off) squares out",
                                why: "redrawn from where the cube says it is")
            replanFromSmartCube()
        }
        if ask { smartCube.askWhereItIs() }
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
        smartCube.onFellAsleep = { [weak self] in self?.cubeFellAsleep() }
        smartCube.onWokeUp = { [weak self] in self?.cubeWokeUp() }
        // The cube's word on where it is disagreed with the app's copy; the copy
        // has been put right, so the picture is held to it. Not asked again —
        // that is the answer.
        smartCube.onPositionCorrected = { [weak self] in
            self?.smartCube.logMoment("the cube's own position differed from the app's copy",
                                      why: "the cube's word was taken")
            self?.holdThePictureToTheCube(andAsk: false)
        }
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

    /// The cube has gone to sleep part way through.
    ///
    /// These cubes nap after a minute or two without a turn — exactly what
    /// happens while a child is studying the screen. Nothing used to notice:
    /// the screen went on saying it was watching, with no Next button, and
    /// waking the cube meant finding the smart cube screen and reading its
    /// name. Now the Next button comes straight back, the child is told, and
    /// the cube connects again by itself the moment it is wiggled.
    private func cubeFellAsleep() {
        guard let session, session.cubeIsFollowing else { return }
        session.cubeIsFollowing = false
        smartCube.logMoment("the cube went to sleep", why: "no turns for a while")
        guard screen == .solving else { return }
        narrator.explain([
            .init("Your cube has gone to sleep. Give it a wiggle to wake it up."),
            .init("Or do the move yourself, and press the big blue Next button.",
                  pointingAt: .next),
        ])
    }

    /// And woken up again: follow it, and check the picture still matches —
    /// it may have been turned while it slept, or Next pressed without it.
    private func cubeWokeUp() {
        guard let session else { return }
        session.cubeIsFollowing = smartCube.isFollowing
        smartCube.logMoment("the cube woke up", why: "it connected again by itself")
        guard screen == .solving else { return }
        narrator.say("Your cube's awake again! Carry on.")
        holdThePictureToTheCube()
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
        // In the picture's own colours, not the usual ones: after the plan has
        // turned the cube round they are different, and this is where a re-plan
        // used to draw a muddled cube.
        let scanned = held.painted(cubeState)
        let whiteFace = scanned.face(withCentre: .white) ?? .D
        do {
            let plan = try session.plan.method.solve(state, whiteFace: whiteFace)
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
        let scanned = held.painted(state)
        let whiteFace = scanned.face(withCentre: .white) ?? .D
        do {
            let plan = try method.solve(asTheyHoldIt, whiteFace: whiteFace)
            scan = scanned
            smartCube.lineUp(withPictureShowing: scanned.centres)
            let fresh = SolveSession(plan: plan, scan: scanned, scene: scene, narrator: narrator)
            follow(fresh)
            session = fresh
            pausedOn = nil
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
