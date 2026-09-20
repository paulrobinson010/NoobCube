import SwiftUI

/// The coaching screen: what to do now, and the cube showing it.
struct SolveView: View {
    @ObservedObject var session: SolveSession
    @ObservedObject var narrator: Narrator
    /// Tapping "look at my cube again" hands back to the camera.
    var onRescan: () -> Void
    var onFinish: () -> Void
    var onHome: () -> Void

    @State private var showingSteps = false
    @State private var showingWhy = false
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
        .sheet(isPresented: $showingWhy) {
            WhySheet(heading: session.currentStep.map(session.heading(of:)) ?? "Why this move",
                     reason: session.wholeReasonForThisStep ?? "",
                     stage: session.stage?.kind,
                     onSpeak: { narrator.say(session.wholeReasonForThisStep ?? "") })
        }
    }

    // MARK: - Pieces

    /// The one move in hand, playing over and over beside the big cube.
    ///
    /// It used to roll the whole set the step was made of, which answers a
    /// question nobody was asking: the child is doing *this* turn, and watching
    /// six of them go by makes it harder to see which one that is, not easier.
    @ViewBuilder
    private var demoCorner: some View {
        if session.showsStepDemo, let move = session.currentMove {
            StepDemoView(moves: [move], colours: session.displayCube.colours)
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
                         onRescan: onRescan,
                         onHome: onHome)

            StageChecklistStrip(stages: session.plan.stages,
                                currentKind: session.stage?.kind,
                                onOpen: { showingSteps = true })
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    @ViewBuilder
    private var instructionCard: some View {
        VStack(spacing: 10) {
            whyBanner
            movesCard
        }
    }

    /// One line of why, over the move it explains.
    ///
    /// The reason used to have a screen of its own, with a button to get past
    /// it, and it was the screen the child kept trying to turn the cube on.
    /// Every screen that is not a move is a screen he does a move on, so the
    /// reason comes to the move instead of the move waiting behind the reason.
    @ViewBuilder
    private var whyBanner: some View {
        if session.help == .moveByMove,
           let why = session.reasonForThisStep,
           let step = session.currentStep {
            HStack(spacing: 8) {
                Image(systemName: "hand.point.up.left.fill")
                    .font(.system(size: 12, weight: .black))
                Text(why)
                    .font(.brand(size: 15, weight: .bold))
                    .lineLimit(2)
                Spacer(minLength: 0)
                ForEach(Array(session.colours(of: step).enumerated()), id: \.offset) { _, colour in
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(colour.swiftUIColor)
                        .frame(width: 16, height: 16)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(.black.opacity(0.35), lineWidth: 1)
                        )
                }
                if step.text != nil {
                    Button {
                        showingWhy = true
                    } label: {
                        Image(systemName: "info.circle.fill")
                            .font(.system(size: 18, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.attention)
                    .accessibilityLabel("Why am I doing this?")
                }
            }
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.done.opacity(0.12))
            )
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
                    stepControls
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

    /// Next, and — when the step has more than one move left — a smaller play
    /// button beside it that does the tapping.
    ///
    /// Eight rightys is eight taps, and eight chances to lose your place. This
    /// runs them a move at a time with a couple of seconds to copy each one,
    /// and Next counts the seconds down rather than sitting there inert.
    private var stepControls: some View {
        HStack(spacing: 10) {
            Button {
                session.isPlayingThrough
                    ? session.stopPlayingThrough()
                    : session.confirmCurrentMove()
            } label: {
                Label(session.isPlayingThrough
                      ? "\(session.secondsUntilNextMove)" : "Next",
                      systemImage: session.isPlayingThrough
                      ? "timer" : "arrow.right.circle.fill")
            }
            .buttonStyle(BigButtonStyle())
            .disabled(session.isBusy || session.currentMove == nil
                      || session.isPlayingThrough)

            if session.canPlayThroughStep || session.isPlayingThrough {
                Button {
                    session.isPlayingThrough
                        ? session.stopPlayingThrough()
                        : session.playThroughTheStep()
                } label: {
                    Image(systemName: session.isPlayingThrough
                          ? "stop.fill" : "play.fill")
                        .font(.system(size: 22, weight: .bold))
                        .frame(width: Theme.minimumTapTarget,
                               height: Theme.minimumTapTarget)
                }
                .buttonStyle(BigButtonStyle(tint: Theme.done, isProminent: false))
                .frame(width: Theme.minimumTapTarget + 16)
                .accessibilityLabel(session.isPlayingThrough
                                    ? "Stop playing the moves"
                                    : "Play the rest of these moves")
            }
        }
    }

}

/// The rest of the reason, for the child who taps the "i".
///
/// It is a sheet rather than a step because a step is a thing you do. This is
/// a thing you read, or more likely a thing a grown-up reads out — which is why
/// it can also be spoken, and why it says which of the eight steps we are on.
struct WhySheet: View {
    let heading: String
    let reason: String
    let stage: SolveStage.Kind?
    var onSpeak: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(heading)
                        .font(.brand(size: 26, weight: .heavy))
                        .foregroundStyle(.white)

                    if !reason.isEmpty {
                        Text(reason)
                            .font(.brand(size: 18, weight: .medium))
                            .foregroundStyle(.white.opacity(0.92))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let stage {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(stage.title)
                                .font(.brand(size: 17, weight: .bold))
                                .foregroundStyle(Theme.done)
                            Text(stage.why)
                                .font(.brand(size: 16, weight: .medium))
                                .foregroundStyle(Theme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .cardBackground(stripe: stage.tint)
                    }

                    Button {
                        onSpeak()
                    } label: {
                        Label("Read it to me", systemImage: "speaker.wave.2.fill")
                    }
                    .buttonStyle(BigButtonStyle(isProminent: false))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Why this move?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Got it") { dismiss() }
                }
            }
        }
    }
}
