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
                         narrator: narrator)

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
            VStack(spacing: 8) {
                nextButton { session.beginStepMoves() }
                rescanButton
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

                    rescanButton
                }

            case .moveByMove:
                VStack(spacing: 8) {
                    nextButton(isEnabled: session.currentMove != nil) {
                        session.confirmCurrentMove()
                    }
                    rescanButton
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

                    rescanButton
                }
            }
        }
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

    /// Small on purpose: a way back to the camera, not somewhere to go.
    private var rescanButton: some View {
        Button {
            onRescan()
        } label: {
            Label("Look at my cube again", systemImage: "camera.fill")
                .font(.brand(size: 15, weight: .semibold))
                .foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity, minHeight: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
