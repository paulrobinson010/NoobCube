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
                              onRescan: { model.rescan() },
                              onFinish: { model.finishSolve() },
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
                .frame(minHeight: 150, maxHeight: 300)
                .layoutPriority(1)
                .onAppear { model.scene.startIdleSpin() }

            Spacer(minLength: 0)

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
                }

                Button {
                    model.startScanning()
                } label: {
                    Label(model.canCarryOn ? "Start again with a new cube" : "Show me your cube",
                          systemImage: "camera.fill")
                }
                .buttonStyle(BigButtonStyle(isProminent: !model.canCarryOn))

                Button {
                    showingSmartCubeSheet = true
                } label: {
                    Label(model.smartCube.isConnected ? "Smart cube connected" : "Use my smart cube",
                          systemImage: "cube.transparent.fill")
                }
                .buttonStyle(BigButtonStyle(tint: model.smartCube.isConnected ? Theme.done : Theme.action,
                                            isProminent: false))

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
