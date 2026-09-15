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

            if session.help == .moveByMove, let stage = session.stage {
                MoveStripView(moves: stage.moves, currentIndex: session.moveIndex)
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
                         subtitle: "Step \(session.stageNumber) of \(session.totalStages)",
                         narrator: narrator)

            StageChecklistStrip(stages: session.plan.stages,
                                currentKind: session.stage?.kind,
                                onOpen: { showingSteps = true })
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    private var instructionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if session.phase == .finished {
                Text("You solved it! 🎉")
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.success)
            } else if session.help == .moveByMove, let move = session.currentMove {
                Text(move.childLabel)
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                Text(move.spokenInstruction)
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
            } else if let stage = session.stage {
                Text(stage.kind.explanation)
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                Text(stage.kind.why)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    @ViewBuilder
    private var controls: some View {
        switch session.phase {
        case .finished:
            VStack(spacing: 12) {
                Button("Play again") { onFinish() }
                    .buttonStyle(BigButtonStyle(tint: Theme.success))
            }

        case .offerRescan:
            VStack(spacing: 12) {
                Text("Let me look at your cube again.")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                Button("Look at my cube") { onRescan() }
                    .buttonStyle(BigButtonStyle())
                Button("Keep going without looking") { session.skipToNextStage() }
                    .buttonStyle(BigButtonStyle(tint: Theme.muted, isProminent: false))
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
                    .buttonStyle(BigButtonStyle(tint: Theme.success, isProminent: false))

                    rescanButton
                }

            case .moveByMove:
                VStack(spacing: 12) {
                    Button {
                        session.confirmCurrentMove()
                    } label: {
                        Label("I did it!", systemImage: "checkmark.circle.fill")
                    }
                    .buttonStyle(BigButtonStyle(tint: Theme.success))
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
                        .buttonStyle(BigButtonStyle(tint: Theme.success))

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
