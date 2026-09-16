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
                .frame(height: 300)
                .padding(.vertical, 4)

            if session.help == .moveByMove, let step = session.currentStep {
                // The step's own moves, not the whole stage's: this is the set
                // that goes together, and the set worth learning.
                MoveStripView(moves: step.moves,
                              currentIndex: session.phase == .introducingStep
                                  ? -1 : session.moveIndexWithinStep)
            }

            // Scrolls rather than squeezing: a long sentence used to be cut
            // off at the bottom of the screen with no way to read the rest.
            ScrollView {
                instructionCard
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
            }
            .frame(maxHeight: 190)

            controls
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
        }
        .background(Theme.background.ignoresSafeArea())
        .onAppear { session.announceCurrentStep() }
        .sheet(isPresented: $showingSteps) {
            StageChecklistSheet(stages: session.plan.stages,
                                currentKind: session.stage?.kind)
        }
    }

    // MARK: - Pieces

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
            VStack(spacing: 12) {
                Button {
                    session.demonstrateStep()
                } label: {
                    Label("Watch it first", systemImage: "play.circle.fill")
                }
                .buttonStyle(BigButtonStyle(tint: Theme.attention))
                .disabled(session.isBusy)

                Button {
                    session.beginStepMoves()
                } label: {
                    Label("Step through it", systemImage: "arrow.turn.up.right")
                }
                .buttonStyle(BigButtonStyle(isProminent: false))
                .disabled(session.isBusy)

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
                VStack(spacing: 12) {
                    Button {
                        session.confirmCurrentMove()
                    } label: {
                        Label("I did it!", systemImage: "checkmark.circle.fill")
                    }
                    .buttonStyle(BigButtonStyle(tint: Theme.done))
                    .disabled(session.isBusy || session.currentMove == nil)

                    Button("Show me that move again") { session.previewCurrentMove() }
                        .buttonStyle(BigButtonStyle(isProminent: false))
                        .disabled(session.isBusy)

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

    private var rescanButton: some View {
        Button {
            onRescan()
        } label: {
            Label("Look at my cube again", systemImage: "camera.fill")
        }
        .buttonStyle(BigButtonStyle(tint: Theme.muted, isProminent: false))
    }
}
