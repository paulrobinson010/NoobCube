import Combine
import SwiftUI

/// Coaches the child through one solve.
///
/// There are two ways to be helped, and the child picks per stage:
///
///   * **Show me each move** — one move at a time, with an arrow and a spoken
///     instruction. They tap to confirm each one.
///   * **I'll do this bit myself** — the goal is explained and the whole stage's
///     moves are listed. When they say they have done it, the app offers a
///     re-scan so it can see where they actually got to.
///
/// A smart cube replaces the tapping: the cube itself says what was turned.
@MainActor
final class SolveSession: ObservableObject {

    enum Help: String, Hashable {
        case undecided
        case moveByMove
        case wholeStage
    }

    enum Phase: Hashable {
        /// Working through the current stage.
        case coaching
        /// The child said they finished a stage themselves; offer a re-scan.
        case offerRescan
        /// Every stage is done.
        case finished
    }

    @Published private(set) var plan: SolvePlan
    @Published private(set) var stageIndex: Int
    @Published private(set) var moveIndex: Int = 0
    @Published private(set) var phase: Phase = .coaching
    @Published var help: Help = .undecided
    @Published private(set) var displayCube: ScannedCube
    /// The cube as it was when the current step was explained.
    ///
    /// The little demo in the corner plays the whole set of moves, so it has to
    /// start from where the set starts, however far through it the child is.
    @Published private(set) var stepStartCube: ScannedCube
    @Published private(set) var isBusy = false

    /// A turn the child made that was not the one asked for, in the app's
    /// words. While this is set the only thing wanted is that turn undone.
    @Published private(set) var wrongTurn: Move?

    /// Whether a connected cube is doing the confirming, so nothing on screen
    /// asks to be tapped for a turn the cube can see for itself.
    @Published var cubeIsFollowing = false

    /// Turns that arrived while the cube on screen was mid-animation.
    private var waitingTurns: [Move] = []

    /// Called when the cube has been turned somewhere the plan no longer
    /// covers, so the plan has to be worked out again from what the cube says.
    var onLost: (() -> Void)?

    /// Called the moment the whole cube comes out solved, so a connected cube
    /// can be told its own position is now a known one.
    var onSolved: (() -> Void)?

    let scene: CubeSceneController
    private let narrator: Narrator
    /// The scan the current plan was made from, kept so a stage can be
    /// replayed. It is replaced along with the plan after a re-scan.
    private var scan: ScannedCube

    init(plan: SolvePlan, scan: ScannedCube, scene: CubeSceneController, narrator: Narrator) {
        self.plan = plan
        self.scan = scan
        self.scene = scene
        self.narrator = narrator
        self.displayCube = scan
        self.stepStartCube = scan
        self.stageIndex = 0
        self.stageIndex = Self.nextWorkableStage(in: plan, from: 0) ?? plan.stages.count
        if self.stageIndex >= plan.stages.count {
            phase = .finished
        }
        scene.setColours(displayCube.colours)
    }

    // MARK: - Where we are

    var stage: SolveStage? {
        plan.stages.indices.contains(stageIndex) ? plan.stages[stageIndex] : nil
    }

    var currentMove: Move? {
        guard let stage, moveIndex < stage.moves.count else { return nil }
        return stage.moves[moveIndex]
    }

    /// The piece being put right at the moment, and the moves that do it.
    var currentStep: SolveStep? { stage?.step(atMove: moveIndex)?.step }

    /// How far into the current step we are, for the move strip.
    var moveIndexWithinStep: Int {
        guard let found = stage?.step(atMove: moveIndex) else { return 0 }
        return moveIndex - found.start
    }

    /// The colours of the piece a step is about, read off the cube as it is
    /// now — which is what the child is looking at.
    func colours(of step: SolveStep) -> [CubeColour] {
        step.piece.compactMap { displayCube[$0.centreIndex] }
    }

    /// "the white and blue edge", "the white, blue and red corner".
    func name(of step: SolveStep) -> String {
        let names = colours(of: step).map(\.spokenName)
        let kind = step.piece.count == 3 ? "corner" : "edge"
        switch names.count {
        case 2: return "the \(names[0]) and \(names[1]) \(kind)"
        case 3: return "the \(names[0]), \(names[1]) and \(names[2]) \(kind)"
        default: return "this piece"
        }
    }

    /// What a step is about, for saying aloud: the piece, then the one line.
    func explanation(of step: SolveStep) -> String {
        var parts: [String] = []
        if !step.piece.isEmpty, step.purpose == .move, step.places {
            parts.append("Now \(name(of: step)) goes where it belongs.")
        }
        if let text = step.text { parts.append(text) }
        return parts.joined(separator: " ")
    }

    /// A few words for the top of the card.
    func heading(of step: SolveStep) -> String {
        if step.purpose == .positioning { return "Get it in place" }
        if let name = step.algorithmName { return name.sentenceCased }
        return step.piece.isEmpty ? "The move" : name(of: step).sentenceCased
    }

    var remainingMoves: [Move] {
        guard let stage else { return [] }
        return Array(stage.moves.dropFirst(moveIndex))
    }

    var totalStages: Int { SolveStage.Kind.totalNumbered }

    /// "Step 3 of 8", or nothing while the cube is still being lined up.
    var stageLabel: String? {
        guard let number = stage?.kind.number else { return nil }
        return "Step \(number) of \(totalStages)"
    }

    /// How far through the whole solve, for the progress bar.
    var progress: Double {
        let total = max(plan.moveCount, 1)
        let doneBefore = plan.stages.prefix(stageIndex).reduce(0) { $0 + $1.moveCount }
        return Double(doneBefore + moveIndex) / Double(total)
    }

    var isFinished: Bool { phase == .finished }

    /// Stages with nothing to do are already solved, so they are skipped.
    private static func nextWorkableStage(in plan: SolvePlan, from index: Int) -> Int? {
        plan.stages.indices.dropFirst(index).first { !plan.stages[$0].isDone }
    }

    // MARK: - Speaking

    /// Introduce the stage the child is now on.
    func announceStage() {
        guard let stage else {
            narrator.say("You did it! The cube is finished. Amazing work!")
            return
        }
        let kind = stage.kind
        let opening = stageLabel.map { "\($0). " } ?? ""
        narrator.say("\(opening)\(kind.title). \(kind.explanation)")
    }

    /// Say the move the child should make now.
    func announceCurrentMove() {
        guard let move = currentMove else { return }
        let remaining = remainingMoves.count
        let tail = remaining == 1 ? " This is the last one for this step." : ""
        narrator.say("\(move.spokenInstruction)\(tail)")
    }

    func announceCurrentStep() {
        if help == .moveByMove, currentMove != nil {
            announceCurrentMove()
        } else {
            announceStage()
        }
    }

    // MARK: - Doing moves

    /// Confirm the current move: animate it, then move on to the next.
    func confirmCurrentMove() {
        guard !isBusy, let move = currentMove else { return }
        isBusy = true
        let wasStep = currentStep
        scene.animate(move, duration: 0.42) { [weak self] in
            guard let self else { return }
            self.displayCube = self.displayCube.applying(move)
            self.moveIndex += 1
            self.isBusy = false
            if self.currentMove == nil {
                self.finishStage()
            } else if self.currentStep != wasStep {
                // A new piece: say what it is before moving it.
                self.introduceStep()
            } else {
                self.presentCurrentMove()
            }
            self.drainTurnsThatArrivedWhileBusy()
        }
    }

    /// Put the arrow up for the current move and say it.
    func presentCurrentMove() {
        guard let move = currentMove else {
            scene.clearHighlight()
            scene.hideTurnArrow()
            return
        }
        scene.hideJourney()
        scene.showTurnArrow(for: move)
        announceCurrentMove()
    }

    func startStage() {
        moveIndex = 0
        wrongTurn = nil
        displayCube = colours(upToStage: stageIndex)
        scene.reset(to: displayCube.colours)
        phase = .coaching
        if help == .moveByMove {
            introduceStep()
        } else {
            scene.hideTurnArrow()
            announceStage()
        }
    }

    /// Begin a new step: the piece being worked on has changed, so the reason
    /// behind the next few moves has too.
    ///
    /// There used to be a screen here, explaining which piece was about to move
    /// and where it was going, with a button to get past it. A five year old
    /// does not read a screen and wait — he turns the cube, because the cube is
    /// in his hands and the app just showed him one. Every screen that is not a
    /// move is a screen he tries to do a move on.
    ///
    /// So the reason lives in a line above the move now, with an "i" for the
    /// rest of it, and every step is a move.
    func introduceStep() {
        stepStartCube = displayCube
        presentCurrentMove()
    }

    /// The one line of why, for the banner over the move.
    var reasonForThisStep: String? {
        guard let step = currentStep, !step.piece.isEmpty, step.places else { return nil }
        return "\(name(of: step).sentenceCased) goes home"
    }

    /// The whole of it, for the child who taps the "i".
    var wholeReasonForThisStep: String? {
        currentStep.map(explanation(of:))
    }

    /// Whether the little rolling demo has a move worth showing.
    var showsStepDemo: Bool {
        help == .moveByMove && currentMove != nil
    }

    private func playSequence(_ moves: [Move], completion: @MainActor @escaping () -> Void) {
        guard let first = moves.first else { return completion() }
        scene.showTurnArrow(for: first)
        scene.animate(first, duration: 0.38) { [weak self] in
            guard let self else { return }
            self.displayCube = self.displayCube.applying(first)
            self.playSequence(Array(moves.dropFirst()), completion: completion)
        }
    }

    /// Play an algorithm through and then wind it straight back, so the child
    /// can watch the shape of it without the cube moving on.
    func previewAlgorithm(_ notation: String) {
        guard !isBusy else { return }
        let moves = Move.parse(notation)
        guard !moves.isEmpty else { return }
        isBusy = true
        narrator.say("Watch this one.")
        playSequence(moves) { [weak self] in
            guard let self else { return }
            self.playSequence(Move.invert(moves)) {
                self.isBusy = false
                self.scene.hideTurnArrow()
            }
        }
    }

    // MARK: - Stage changes

    private func finishStage() {
        scene.hideTurnArrow()
        scene.clearHighlight()
        guard let next = Self.nextWorkableStage(in: plan, from: stageIndex + 1) else {
            phase = .finished
            narrator.say("You did it! The whole cube is finished. Well done!")
            onSolved?()
            return
        }
        stageIndex = next
        help = .undecided
        narrator.say("Nice one, that step is done. \(plan.stages[next].kind.title) is next.")
        startStage()
    }

    /// The child says they have done the whole stage themselves.
    func declareStageDoneByHand() {
        phase = .offerRescan
        narrator.say("Great. Let me look at your cube again to see how you got on.")
    }

    func skipToNextStage() {
        guard let next = Self.nextWorkableStage(in: plan, from: stageIndex + 1) else {
            phase = .finished
            return
        }
        stageIndex = next
        help = .undecided
        startStage()
    }

    /// Replace the plan after a re-scan, keeping the same session on screen.
    func replacePlan(_ newPlan: SolvePlan, scan newScan: ScannedCube) {
        plan = newPlan
        wrongTurn = nil
        waitingTurns.removeAll()
        scan = newScan
        moveIndex = 0
        stageIndex = Self.nextWorkableStage(in: newPlan, from: 0) ?? newPlan.stages.count
        displayCube = newScan
        stepStartCube = newScan
        scene.reset(to: newScan.colours)
        if stageIndex >= newPlan.stages.count {
            phase = .finished
            narrator.say("You did it! The whole cube is finished. Well done!")
            onSolved?()
        } else {
            phase = .coaching
            help = .undecided
            announceStage()
        }
    }

    /// The cube's colours at the start of a given stage.
    private func colours(upToStage index: Int) -> ScannedCube {
        let moves = plan.stages.prefix(index).flatMap(\.moves)
        return scan.applying(moves)
    }

    // MARK: - Smart cube

    /// A turn reported by a connected smart cube, already said in the app's
    /// words rather than the cube's.
    ///
    /// The point of a connected cube is that nothing needs confirming: the cube
    /// says what happened, so the app can tell the child whether it was right
    /// and what to do next without anybody pressing anything.
    ///
    /// A child turning a cube is quicker than an animation of one, so turns
    /// that land mid-animation are kept and dealt with in order rather than
    /// dropped. Dropping one is the worst thing that could happen here: the
    /// screen would quietly stop matching the cube in their hands, and every
    /// instruction after it would be wrong.
    func handleSmartCubeTurn(_ move: Move) {
        guard !isBusy else {
            waitingTurns.append(move)
            return
        }

        if let wrong = wrongTurn {
            guard move == wrong.inverse else { return giveUpAndReplan() }
            wrongTurn = nil
            narrator.say("That's it. Carry on.")
            playTheirTurn(move) { [weak self] in self?.presentCurrentMove() }
            return
        }

        guard let expected = currentMove else { return giveUpAndReplan() }

        // Nothing has been asked of them yet.
        //
        // At the start of a stage the child is still being asked whether they
        // want to do it themselves or be walked through it move by move, and
        // until they answer, no move has been put in front of them. A turn now
        // cannot be the wrong one, because there was no right one — being told
        // "not that one" before being told anything at all is the app blaming a
        // child for its own impatience.
        //
        // Turning the cube is them getting on with it, so that is what it is
        // taken as: the move the plan wanted moves them along, and anything
        // else is simply where their cube is now, worked out again without
        // comment.
        if help == .undecided {
            if !expected.isWholeCubeTurn, move == expected {
                help = .wholeStage
                confirmCurrentMove()
                return
            }
            // Unless it undoes work they have already done. Turning a side at
            // the start of the middle row can take the finished white layer
            // apart, and quietly re-planning from there sends a child back over
            // ground they had won without ever saying why. They just made the
            // move, so the way back is one turn, and it is worth offering
            // before the plan accepts it.
            if let backwards = stageThisWouldGoBackTo(after: move) {
                wrongTurn = move
                narrator.say("Careful — that takes your \(backwards) apart. "
                             + "\(move.inverse.spokenInstruction) to put it back.")
                playTheirTurn(move) { [weak self] in self?.showTheWayBack() }
                return
            }
            return playTheirTurn(move) { [weak self] in self?.replanQuietly() }
        }

        // Whole-cube turns are dealt with before we get here, by
        // ``takeTheTurnAsDone(andThen:)``, because the mapping of the turn that
        // dismissed them depends on their having happened.
        guard !expected.isWholeCubeTurn, move == expected else {
            wrongTurn = move
            narrator.say("Not that one. \(move.inverse.spokenInstruction) to put it back.")
            playTheirTurn(move) { [weak self] in self?.showTheWayBack() }
            return
        }

        // Turning the cube is the child saying they are ready, so a step being
        // explained gets on with it rather than waiting for a tap as well.
        confirmCurrentMove()
    }

    /// Turned again while already off the path. The cube is somewhere nobody is
    /// tracking now, so the plan is worked out afresh from where it actually is
    /// rather than argued with.
    private func giveUpAndReplan() {
        wrongTurn = nil
        waitingTurns.removeAll()
        narrator.say("Let me work out where your cube is now.")
        onLost?()
    }

    /// The stage this turn would send them back to, if it undoes finished work.
    ///
    /// Worked out by solving the cube as it would be afterwards and seeing
    /// where that plan starts. Stages already finished come back empty, so the
    /// first one with anything in it is how far along the cube really is — if
    /// that is earlier than the stage in hand, the turn took something apart.
    ///
    /// Nil for a turn that costs nothing, which most of them do: spinning the
    /// top, or turning the whole cube round, leaves every finished layer
    /// finished and is none of the app's business.
    private func stageThisWouldGoBackTo(after move: Move) -> String? {
        // Turning the whole cube round moves nothing relative to anything else,
        // so it can never take a finished layer apart. Worth saying outright
        // rather than working out: a rotation also moves the middles, and a
        // cube read back with its middles somewhere new is not the cube the
        // solver thinks it is being handed.
        guard !move.isWholeCubeTurn, let current = stage?.kind else { return nil }
        guard let after = try? displayCube.applying(move).cubeState(),
              let ahead = try? BeginnerSolver.solve(after.state, whiteFace: after.whiteFace),
              let reached = ahead.stages.first(where: { !$0.steps.isEmpty })?.kind,
              reached.howFarThrough < current.howFarThrough else { return nil }
        return reached.whatItTakesApart
    }

    /// The same thing without saying so.
    ///
    /// For a turn made before anything was asked for: their cube is somewhere
    /// new, the plan follows it there, and none of that is the child's
    /// business.
    private func replanQuietly() {
        wrongTurn = nil
        waitingTurns.removeAll()
        onLost?()
    }

    private func drainTurnsThatArrivedWhileBusy() {
        guard !waitingTurns.isEmpty else { return }
        let next = waitingTurns.removeFirst()
        handleSmartCubeTurn(next)
    }

    /// Put a turn the child made on screen without moving them along, so what
    /// they are looking at always matches what is in their hands.
    private func playTheirTurn(_ move: Move, then finish: @MainActor @escaping () -> Void) {
        isBusy = true
        scene.hideTurnArrow()
        scene.hideJourney()
        scene.animate(move, duration: 0.3) { [weak self] in
            guard let self else { return }
            self.displayCube = self.displayCube.applying(move)
            self.isBusy = false
            finish()
            self.drainTurnsThatArrivedWhileBusy()
        }
    }

    /// The whole-cube turns the plan is waiting on right now.
    ///
    /// A run rather than one, because a plan can ask for two in a row and the
    /// child does them as a single movement of their hands.
    var pendingWholeCubeTurns: [Move] {
        guard let stage else { return [] }
        return Array(stage.moves.dropFirst(moveIndex).prefix(while: \.isWholeCubeTurn))
    }

    /// The first real move after them, which is the one a turn can match.
    var moveAfterWholeCubeTurns: Move? {
        guard let stage else { return nil }
        let index = moveIndex + pendingWholeCubeTurns.count
        return stage.moves.indices.contains(index) ? stage.moves[index] : nil
    }

    /// The child says they have turned the whole cube round.
    ///
    /// Goes through the same door a real turn would, so being told about a step
    /// and getting on with it are not two taps.
    func confirmWholeCubeTurn() {
        guard !isBusy, currentMove?.isWholeCubeTurn == true else { return }
        confirmCurrentMove()
    }

    /// Take the whole-cube turns we are waiting on as already done.
    ///
    /// A cube cannot feel itself being turned round in your hands, so the only
    /// evidence it ever gives is the child getting on with the next move. That
    /// is evidence enough: waiting for a tap after they have plainly moved on
    /// leaves them stuck in front of an instruction they have already followed.
    func takeTheTurnAsDone(andThen move: Move) {
        guard !isBusy else {
            waitingTurns.append(move)
            return
        }
        let spins = pendingWholeCubeTurns
        guard !spins.isEmpty else { return handleSmartCubeTurn(move) }

        // Whether they turned it and got the next move right, or turned it and
        // got the next move wrong, they turned it. Only the words differ.
        if move == moveAfterWholeCubeTurns {
            narrator.say("You turned it round. Good — carry on.")
        }
        isBusy = true
        playSpins(spins) { [weak self] in
            guard let self else { return }
            self.isBusy = false
            self.phase = .coaching
            self.handleSmartCubeTurn(move)
        }
    }

    private func playSpins(_ spins: [Move], then finish: @MainActor @escaping () -> Void) {
        guard let spin = spins.first else { return finish() }
        scene.hideTurnArrow()
        scene.hideJourney()
        scene.animate(spin, duration: 0.34) { [weak self] in
            guard let self else { return }
            self.displayCube = self.displayCube.applying(spin)
            self.moveIndex += 1
            self.playSpins(Array(spins.dropFirst()), then: finish)
        }
    }

    /// Forget a mistake without acting on it, for when it turns out the app
    /// was wrong about what the child did rather than the other way round.
    func forgetTheMistake() {
        wrongTurn = nil
        waitingTurns.removeAll()
        presentCurrentMove()
    }

    /// Put the arrow back on the turn that undoes a mistake.
    func showTheWayBack() {
        guard let wrong = wrongTurn else { return }
        scene.hideJourney()
        scene.highlight(square: nil)
        scene.showTurnArrow(for: wrong.inverse)
    }

    /// What the screen should be asking of the child right now.
    ///
    /// One rule in one place. It used to be a predicate here and an order of
    /// checks in the view, which is two rules that can drift apart, and the
    /// first thing to go wrong would have been the screen asking for a tap
    /// that no longer did anything.
    enum Prompt: Equatable {
        /// No cube connected: every move is confirmed by hand.
        case tapWhenDone
        /// The one thing no cube can feel — it turns no layer. Not a gate:
        /// turning any layer dismisses it.
        case turnTheWholeCube
        /// A cube is watching; nothing to press.
        case watching
        /// A turn that was not the one asked for, waiting to be undone.
        case putItBack(Move)
    }

    var prompt: Prompt {
        if let wrong = wrongTurn { return .putItBack(wrong) }
        guard cubeIsFollowing else { return .tapWhenDone }
        if currentMove?.isWholeCubeTurn == true { return .turnTheWholeCube }
        return .watching
    }

    /// Every whole-cube turn the plan has made so far.
    ///
    /// Turning the whole cube leaves the cube's own frame where it was and
    /// moves the app's, so a connected cube has to be lined up again after each
    /// one. Counted from the plan rather than tallied as they happen, so
    /// starting a stage over cannot leave the two out of step.
    var wholeCubeTurnsSoFar: [Move] {
        let before = plan.stages.prefix(stageIndex).flatMap(\.moves)
        let during = stage.map { Array($0.moves.prefix(moveIndex)) } ?? []
        return (before + during).filter(\.isWholeCubeTurn)
    }
}
