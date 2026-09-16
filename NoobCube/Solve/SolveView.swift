import SwiftUI

/// The coaching screen: what to do now, and the cube showing it.
struct SolveView: View {
    @ObservedObject var session: SolveSession
    @ObservedObject var narrator: Narrator
    /// Tapping "look at my cube again" hands back to the camera.
    var onRescan: () -> Void
    var onFinish: () -> Void

    @State private var showingSteps = false
    @State private var algorithmCovered = false

    var body: some View {
        VStack(spacing: 0) {
            header

            CubeSceneView(controller: session.scene)
                .frame(maxWidth: .infinity)
                .frame(height: 276)
                .padding(.vertical, 4)
                .overlay(alignment: .bottomTrailing) { demoCorner }

            if session.help == .moveByMove {
                // Only once the moves have started. Showing the set beside the
                // arrow that says where a piece is going put a single move on
                // screen next to a journey it does not make on its own, and
                // read as a contradiction.
                Group {
                    if session.phase == .coaching, let step = session.currentStep {
                        MoveStripView(moves: step.moves,
                                      currentIndex: session.moveIndexWithinStep)
                    } else if let step = session.currentStep {
                        Text(step.moves.count == 1
                             ? "One move to do"
                             : "\(step.moves.count) moves, one after the other")
                            .font(.brand(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.muted)
                    }
                }
                .frame(height: 76)
            }

            // Takes whatever room is left, and scrolls if the sentence is
            // longer than that: it used to be given a fixed slice of the screen
            // and then covered by the buttons underneath it.
            ScrollView {
                instructionCard
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            controls
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
        }
        .background(Theme.background.ignoresSafeArea())
        .onAppear { session.announceCurrentStep() }
        .sheet(isPresented: $showingSteps) {
            StageChecklistSheet(stages: session.plan.stages,
                                currentKind: session.stage?.kind)
        }
    }

    // MARK: - Pieces

    /// The whole set of moves, playing over and over beside the big cube.
    @ViewBuilder
    private var demoCorner: some View {
        if session.showsStepDemo, let step = session.currentStep {
            StepDemoView(moves: step.moves, colours: session.stepStartCube.colours)
                .padding(.trailing, 18)
                .padding(.bottom, 2)
                .transition(.scale.combined(with: .opacity))
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            ScreenHeader(title: session.stage?.kind.title ?? "All done!",
                         subtitle: session.stageLabel,
                         narrator: narrator,
                         onRescan: onRescan)

            StageChecklistStrip(stages: session.plan.stages,
                                currentKind: session.stage?.kind,
                                onOpen: { showingSteps = true })
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    /// What is about to happen, before it happens.
    ///
    /// One line, because it is one thing: either getting a square where we can
    /// work on it, or the move that puts it home. Two jobs in one paragraph is
    /// what made this unreadable, and too long for the screen besides.
    private func stepCard(_ step: SolveStep) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: step.purpose == .positioning
                      ? "arrow.up.and.down.and.arrow.left.and.right"
                      : "hand.point.up.left.fill")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(step.purpose == .positioning ? Theme.attention : Theme.done)
                Text(session.heading(of: step))
                    .font(.brand(size: 20, weight: .heavy))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
                ForEach(Array(session.colours(of: step).enumerated()), id: \.offset) { _, colour in
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(colour.swiftUIColor)
                        .frame(width: 22, height: 22)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(.black.opacity(0.35), lineWidth: 1)
                        )
                }
            }

            if let text = step.text {
                Text(text)
                    .font(.brand(size: 17, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground(stripe: step.purpose == .positioning ? Theme.attention : Theme.done)
    }

    @ViewBuilder
    private var instructionCard: some View {
        if session.phase == .introducingStep, let step = session.currentStep {
            stepCard(step)
        } else {
            movesCard
        }
    }

    private var movesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if session.phase == .finished {
                Text("You solved it! 🎉")
                    .font(.brand(size: 30, weight: .heavy))
                    .foregroundStyle(Theme.done)
            } else if session.help == .moveByMove, let move = session.currentMove {
                Text(move.childLabel)
                    .font(.brand(size: 30, weight: .heavy))
                    .foregroundStyle(.white)
                Text(move.spokenInstruction)
                    .font(.brand(size: 18, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
            } else if let stage = session.stage {
                Text(stage.kind.explanation)
                    .font(.brand(size: 18, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                Text(stage.kind.why)
                    .font(.brand(size: 15, weight: .medium))
                    .foregroundStyle(Theme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground(stripe: session.stage?.kind.tint ?? Theme.done)
    }

    @ViewBuilder
    private var controls: some View {
        switch session.phase {
        case .finished:
            VStack(spacing: 12) {
                Button("Play again") { onFinish() }
                    .buttonStyle(BigButtonStyle(tint: Theme.done))
            }

        case .offerRescan:
            VStack(spacing: 12) {
                Text("Let me look at your cube again.")
                    .font(.brand(size: 18, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Button("Look at my cube") { onRescan() }
                    .buttonStyle(BigButtonStyle())
                Button("Keep going without looking") { session.skipToNextStage() }
                    .buttonStyle(BigButtonStyle(tint: Theme.muted, isProminent: false))
            }

        case .introducingStep:
            // A whole-cube turn is the one thing that still wants a tap, and it
            // wants it here too — otherwise a step that opens with one leaves
            // nothing to press and nothing the cube can feel.
            switch session.prompt {
            case .turnTheWholeCube:
                turnTheWholeCube
            case .tapWhenDone:
                nextButton { session.beginStepMoves() }
            case .watching, .putItBack:
                watchingPrompt("Turn your cube when you're ready.")
            }

        case .coaching:
            switch session.help {
            case .undecided:
                VStack(spacing: 12) {
                    Button("Show me each move") {
                        session.help = .moveByMove
                        session.startStage()
                    }
                    .buttonStyle(BigButtonStyle())

                    Button("I'll do this bit myself") {
                        session.help = .wholeStage
                        session.announceStage()
                    }
                    .buttonStyle(BigButtonStyle(tint: Theme.done, isProminent: false))
                }

            case .moveByMove:
                switch session.prompt {
                case .putItBack(let wrong):
                    putItBack(wrong)
                case .turnTheWholeCube:
                    turnTheWholeCube
                case .tapWhenDone:
                    nextButton(isEnabled: session.currentMove != nil) {
                        session.confirmCurrentMove()
                    }
                case .watching:
                    watchingPrompt("Go on then — I'm watching.")
                }

            case .wholeStage:
                VStack(spacing: 12) {
                    if let algorithm = session.stage?.kind.algorithm {
                        AlgorithmCardView(name: algorithm.name,
                                          moves: Move.parse(algorithm.moves),
                                          covered: $algorithmCovered,
                                          onPlay: { session.previewAlgorithm(algorithm.moves) })
                    } else if let stage = session.stage {
                        MoveStripView(moves: stage.moves, currentIndex: -1)
                            .frame(height: 76)
                    }
                    Button("I've done this bit") { session.declareStageDoneByHand() }
                        .buttonStyle(BigButtonStyle(tint: Theme.done))

                    Button("Actually, show me each move") {
                        session.help = .moveByMove
                        session.startStage()
                    }
                    .buttonStyle(BigButtonStyle(isProminent: false))
                }
            }
        }
    }

    /// The one instruction a connected cube cannot see for itself.
    ///
    /// No cube can feel itself being turned round in your hands, so this is the
    /// only thing left that asks to be confirmed — and it says what it is
    /// confirming rather than just "Next". It is not a gate, though: turning
    /// any layer dismisses it, because a child turning layers has plainly
    /// already turned the cube round.
    private var turnTheWholeCube: some View {
        VStack(spacing: 10) {
            Text("I can\u{2019}t feel the whole cube turning — tell me when you have.")
                .font(.brand(size: 15, weight: .medium))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
            Button {
                session.confirmWholeCubeTurn()
            } label: {
                Label("I\u{2019}ve turned it", systemImage: "checkmark.circle.fill")
            }
            .buttonStyle(BigButtonStyle())
            .disabled(session.isBusy)
        }
    }

    /// What stands in for the button when a cube is connected.
    ///
    /// With the cube reporting every turn there is nothing to confirm, so a
    /// button would only be a thing to press that changes nothing. The child
    /// turns their cube and the app keeps up.
    private func watchingPrompt(_ words: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 18, weight: .black))
            Text(words)
                .font(.brand(size: 19, weight: .bold))
        }
        .foregroundStyle(Theme.done)
        .frame(maxWidth: .infinity)
        .frame(height: 58)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Theme.done.opacity(0.14))
        )
    }

    /// A wrong turn, and the one turn that undoes it.
    ///
    /// Being told only that it is wrong leaves a five year old stuck with a
    /// cube they have just made worse. One turn back is always the way out,
    /// and it is the same kind of instruction as every other one here.
    private func putItBack(_ wrong: Move) -> some View {
        VStack(spacing: 8) {
            Text("That wasn't the one.")
                .font(.brand(size: 18, weight: .bold))
                .foregroundStyle(Theme.attention)
            Text("\(wrong.inverse.childLabel) — \(wrong.inverse.spokenInstruction)")
                .font(.brand(size: 17, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Theme.attention.opacity(0.14))
        )
    }

    /// The only button on the screen while a step is being worked through.
    ///
    /// Every choice that used to sit here — watch it, step through it, show me
    /// again — was a decision a five year old had to make before they could get
    /// on with the cube. The demo runs by itself now, so this is all that is
    /// left: one thing to press, that always means the same thing.
    private func nextButton(isEnabled: Bool = true,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label("Next", systemImage: "arrow.right.circle.fill")
        }
        .buttonStyle(BigButtonStyle())
        .disabled(session.isBusy || !isEnabled)
    }

}
