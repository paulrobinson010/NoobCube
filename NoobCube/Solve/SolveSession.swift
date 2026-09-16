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
        /// Saying which piece is about to move and where it is going, before
        /// any of the moves that do it.
        case introducingStep
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
    @Published private(set) var isBusy = false

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
        if phase == .introducingStep, let step = currentStep {
            narrator.say(explanation(of: step))
        } else if help == .moveByMove, currentMove != nil {
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
        }
    }

    /// Show the move again without moving on: turn it, then turn it back.
    func previewCurrentMove() {
        guard !isBusy, let move = currentMove else { return }
        isBusy = true
        scene.animate(move, duration: 0.42) { [weak self] in
            guard let self else { return }
            self.scene.animate(move.inverse, duration: 0.32) {
                self.isBusy = false
                self.presentCurrentMove()
            }
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

    /// Say what the next piece is and where it is going, before moving it.
    ///
    /// This is the part that turns copying into learning. The moves on their
    /// own are a recipe; knowing that *this* piece is going into *that* gap,
    /// and that you line it up first, is the thing a child can still do
    /// tomorrow without the app.
    func introduceStep() {
        guard help == .moveByMove, let step = currentStep, currentMove != nil else {
            phase = .coaching
            presentCurrentMove()
            return
        }
        phase = .introducingStep
        scene.hideTurnArrow()
        showStepMarks()
        narrator.say(explanation(of: step))
    }

    /// Show what this step is about: the one square, and where it is going.
    func showStepMarks() {
        guard let step = currentStep else { return }

        // Turning the whole cube moves nothing *on* the cube, so an arrow from
        // one square to another says nothing — it just draws a line between two
        // places that stay exactly where they are relative to each other. The
        // curled arrow, which means "spin this round", is the honest picture.
        if let spin = step.moves.first, step.moves.allSatisfy(\.isWholeCubeTurn) {
            scene.highlight(square: nil)
            scene.hideJourney()
            scene.showTurnArrow(for: spin)
            return
        }

        scene.hideTurnArrow()
        scene.highlight(square: step.marker)
        if let marker = step.marker, let target = step.target {
            scene.showJourney(from: marker, to: target)
        } else {
            scene.hideJourney()
        }
    }

    /// Get on with the moves for the step just explained.
    func beginStepMoves() {
        phase = .coaching
        presentCurrentMove()
    }

    /// Play the whole step through and wind it straight back, so the child can
    /// watch the piece travel before trying it themselves.
    func demonstrateStep() {
        guard !isBusy, let step = currentStep, !step.moves.isEmpty else { return }
        isBusy = true
        narrator.say("Watch where it goes.")
        playSequence(step.moves) { [weak self] in
            guard let self else { return }
            self.playSequence(Move.invert(step.moves)) {
                self.isBusy = false
                self.scene.hideTurnArrow()
                self.showStepMarks()
            }
        }
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
        scan = newScan
        moveIndex = 0
        stageIndex = Self.nextWorkableStage(in: newPlan, from: 0) ?? newPlan.stages.count
        displayCube = newScan
        scene.reset(to: newScan.colours)
        if stageIndex >= newPlan.stages.count {
            phase = .finished
            narrator.say("You did it! The whole cube is finished. Well done!")
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

    /// A turn reported by a connected smart cube.
    ///
    /// If it is the move we asked for, the child is simply moved along. If it is
    /// anything else, the cube itself is now the source of truth, so the caller
    /// re-plans from the cube's own state rather than arguing with it.
    func handleSmartCubeTurn(_ move: Move) -> Bool {
        guard let expected = currentMove else { return false }
        guard move == expected else { return false }
        // Turning the cube is the child saying they are ready, so a step being
        // explained gets on with it rather than waiting for a tap as well.
        if phase == .introducingStep { beginStepMoves() }
        confirmCurrentMove()
        return true
    }
}
