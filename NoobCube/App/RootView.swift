import SwiftUI

struct RootView: View {
    @StateObject private var model = AppModel()

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            switch model.screen {
            case .welcome:
                WelcomeView(model: model)
                    .transition(.opacity)

            case .scanning:
                ScanView(coordinator: model.scanCoordinator,
                         narrator: model.narrator,
                         onReady: { state, whiteFace, scan in
                             model.scanFinished(state: state, whiteFace: whiteFace, scan: scan)
                         },
                         onCancel: { model.showWelcome() })
                    .transition(.opacity)

            case .ready:
                if let scan = model.scan {
                    ReadyView(scan: scan,
                              scene: model.scene,
                              narrator: model.narrator,
                              onStart: { model.beginSolving() },
                              onHome: { model.goHome() })
                        .transition(.opacity)
                }

            case .solving:
                if let session = model.session {
                    SolveView(session: session,
                              narrator: model.narrator,
                              voice: model.voice,
                              onToggleListening: { model.toggleListening() },
                              onShowing: { model.solveScreenIsShowing($0) },
                              onRescan: { model.rescan() },
                              onFinish: { model.finishSolve() },
                              onSolveAgain: { model.solveAgain() },
                              onHome: { model.goHome() })
                        .transition(.opacity)
                }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: model.screen)
        .preferredColorScheme(.dark)
        .alert("Hmm", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

/// The first screen: a slowly turning cube and one big button.
struct WelcomeView: View {
    @ObservedObject var model: AppModel
    @State private var showingSmartCubeSheet = false

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 8)

            BrandWordmark(height: 54)
                .padding(.top, 4)

            Text("Let's solve your cube together")
                .font(.brand(size: 19, weight: .semibold))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)

            // Gives way on a small phone, now there can be three buttons under
            // it: a fixed 300 points pushed the last of them off the screen.
            CubeSceneView(controller: model.scene)
                .frame(minHeight: 110, maxHeight: 300)
                .layoutPriority(1)
                .onAppear { model.scene.startIdleSpin() }

            Spacer(minLength: 0)

            MethodPicker(model: model)
                .padding(.horizontal, 20)

            VStack(spacing: 12) {
                // A solve they left part way through comes first, so going home
                // is never the end of it.
                if model.canCarryOn {
                    Button {
                        model.carryOn()
                    } label: {
                        Label("Carry on solving", systemImage: "play.fill")
                    }
                    .buttonStyle(BigButtonStyle(tint: Theme.done))
                    .pointedAt(.carryOn, by: model.narrator)
                }

                Button {
                    model.startScanning()
                } label: {
                    Label(model.canCarryOn ? "Start again with a new cube" : "Show me your cube",
                          systemImage: "camera.fill")
                }
                .buttonStyle(BigButtonStyle(isProminent: !model.canCarryOn))
                .pointedAt(.showMeYourCube, by: model.narrator)

                Button {
                    showingSmartCubeSheet = true
                } label: {
                    Label(model.smartCube.isConnected ? "Smart cube connected" : "Use my smart cube",
                          systemImage: "cube.transparent.fill")
                }
                .buttonStyle(BigButtonStyle(tint: model.smartCube.isConnected ? Theme.done : Theme.action,
                                            isProminent: false))
                .pointedAt(.smartCube, by: model.narrator)

                HStack {
                    Spacer()
                    NarratorControls(narrator: model.narrator)
                    Spacer()
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        // Every time home comes up, including coming back to it part way
        // through a solve: what each button does, with each one pointed at.
        .onAppear { model.explainTheHomeScreen() }
        .sheet(isPresented: $showingSmartCubeSheet) {
            SmartCubeView(manager: model.smartCube,
                          narrator: model.narrator,
                          onUseCube: {
                              showingSmartCubeSheet = false
                              model.startFromSmartCube()
                          },
                          onUseCamera: {
                              showingSmartCubeSheet = false
                              model.startScanning()
                          },
                          onCalibrateSolved: { model.smartCubeIsSolved() })
        }
    }
}

/// Beginner, Faster or Speedcuber, side by side: a walking figure, a hare and
/// a lightning bolt, so the choice can be made from the pictures alone.
struct MethodPicker: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            ForEach(SolveMethod.allCases, id: \.self) { method in
                let chosen = method == model.method
                Button {
                    model.choose(method)
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: method.symbol)
                            .font(.system(size: 22, weight: .bold))
                        Text(method.title)
                            .font(.brand(size: 16, weight: .bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .foregroundStyle(chosen ? Theme.action.readableText : Theme.muted)
                    .frame(maxWidth: .infinity, minHeight: Theme.minimumTapTarget)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(chosen ? Theme.action : Theme.card)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(method.title): \(method.subtitle)")
                .accessibilityAddTraits(chosen ? .isSelected : [])
                .pointedAt(method.button, by: model.narrator)
            }
        }
    }
}

extension SolveMethod {

    /// The picture on its button.
    var symbol: String {
        switch self {
        case .beginner:   return "figure.walk"
        case .faster:     return "hare.fill"
        case .speedcuber: return "bolt.fill"
        }
    }

    /// Its button, for the voice to point at.
    var button: Narrator.ButtonName {
        switch self {
        case .beginner:   return .methodBeginner
        case .faster:     return .methodFaster
        case .speedcuber: return .methodSpeedcuber
        }
    }
}
