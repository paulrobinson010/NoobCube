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

            instructionCard
                .padding(.horizontal, 20)
                .padding(.top, 8)

            Spacer(minLength: 8)

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

    /// What is about to happen, before it happens: which piece, going where.
    @ViewBuilder
    private func stepCard(_ step: SolveStep) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ForEach(Array(session.colours(of: step).enumerated()), id: \.offset) { _, colour in
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(colour.swiftUIColor)
                        .frame(width: 26, height: 26)
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(.black.opacity(0.35), lineWidth: 1)
                        )
                }
                if !step.piece.isEmpty {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(Theme.done)
                    Text(step.places ? "goes home" : "out of the way")
                        .font(.brand(size: 16, weight: .bold))
                        .foregroundStyle(Theme.done)
                }
            }

            if !step.piece.isEmpty {
                Text(session.name(of: step).sentenceCased)
                    .font(.brand(size: 24, weight: .heavy))
                    .foregroundStyle(.white)
            }

            if let lineUp = step.lineUpText {
                Label(lineUp, systemImage: "scope")
                    .font(.brand(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
            }
            if let outcome = step.outcome {
                Text(outcome)
                    .font(.brand(size: 15, weight: .medium))
                    .foregroundStyle(Theme.muted)
            }
            if let name = step.algorithmName {
                Text("Then \(name): \(step.algorithm.map(\.notation).joined(separator: " "))")
                    .font(.brand(size: 15, weight: .bold))
                    .foregroundStyle(Theme.attention)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground(stripe: Theme.attention)
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
                    session.beginStepMoves()
                } label: {
                    Label("Show me how", systemImage: "arrow.turn.up.right")
                }
                .buttonStyle(BigButtonStyle())
                .disabled(session.isBusy)

                Button("Watch it happen first") { session.demonstrateStep() }
                    .buttonStyle(BigButtonStyle(tint: Theme.attention, isProminent: false))
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

                    HStack(spacing: 12) {
                        Button("Show me again") { session.previewCurrentMove() }
                            .buttonStyle(BigButtonStyle(isProminent: false))
                            .disabled(session.isBusy)

                        Button("Do the rest") { session.playWholeStage() }
                            .buttonStyle(BigButtonStyle(tint: Theme.muted, isProminent: false))
                            .disabled(session.isBusy)
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

    private var rescanButton: some View {
        Button {
            onRescan()
        } label: {
            Label("Look at my cube again", systemImage: "camera.fill")
        }
        .buttonStyle(BigButtonStyle(tint: Theme.muted, isProminent: false))
    }
}
