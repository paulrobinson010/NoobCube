import SwiftUI
import UIKit

/// Finding and connecting a smart cube.
struct SmartCubeView: View {
    @ObservedObject var manager: SmartCubeManager
    @ObservedObject var narrator: Narrator
    var onUseCube: () -> Void
    var onUseCamera: () -> Void
    var onCalibrateSolved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isChecking = false
    @State private var isReadingTheLog = false
    @State private var showsGrownUpThings = false

    var body: some View {
        NavigationStack {
            // Scrolls, because a connected cube now has more under it than a
            // phone is tall: the picture, four ways on, and the move log.
            ScrollView {
                VStack(spacing: 16) {
                    statusCard

                    if manager.isConnected {
                        connectedControls
                    } else {
                        cubeList
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Smart cube")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                // Held down for a second and a half, never a tap, so it is not
                // found by accident.
                ToolbarItem(placement: .primaryAction) {
                    Image(systemName: "gearshape")
                        .foregroundStyle(Theme.muted.opacity(showsGrownUpThings ? 1 : 0.5))
                        .padding(8)
                        .contentShape(Rectangle())
                        .onLongPressGesture(minimumDuration: 1.5) {
                            withAnimation { showsGrownUpThings.toggle() }
                        }
                        .accessibilityLabel("Grown-up settings. Hold down to open.")
                }
            }
        }
        .onAppear {
            manager.startScanning()
            explainWhereWeAre()
        }
        .onChange(of: manager.status) { _, _ in explainWhereWeAre() }
        .onChange(of: manager.discovered.count) { _, count in
            if count == 2 { explainWhereWeAre() }
        }
        .onChange(of: manager.hasSaidWhatItLooksLike) { _, _ in explainWhereWeAre() }
        .onDisappear { manager.stopScanning() }
        .sheet(isPresented: $isChecking) { SmartCubeCheckView(manager: manager) }
        .sheet(isPresented: $isReadingTheLog) { TurnLogView(manager: manager) }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(statusTitle)
                .font(.brand(size: 22, weight: .heavy))
                .foregroundStyle(.white)
            Text(statusDetail)
                .font(.brand(size: 16, weight: .medium))
                .foregroundStyle(Theme.muted)
            if let battery = manager.batteryPercent {
                Label("\(battery)%", systemImage: "battery.100")
                    .font(.brand(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.done)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    private var cubeList: some View {
        VStack(spacing: 10) {
            if manager.status == .bluetoothOff || manager.status == .unauthorised {
                // Only a grown-up can fix this, in Settings.
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label(manager.status == .bluetoothOff ? "Turn Bluetooth on" : "Let NoobCube use Bluetooth",
                          systemImage: "gearshape.fill")
                }
                .buttonStyle(BigButtonStyle())
                .pointedAt(.openSettings, by: narrator)
            } else if manager.discovered.isEmpty {
                ProgressView()
                    .tint(Theme.attention)
                    .padding(.top, 20)
                Text("Wiggle your cube to wake it up.")
                    .font(.brand(size: 16, weight: .medium))
                    .foregroundStyle(Theme.muted)
            }
            VStack(spacing: 10) {
                ForEach(manager.discovered) { cube in
                    Button {
                        manager.connect(cube)
                    } label: {
                        HStack {
                            Image(systemName: "cube.fill")
                            Text(cube.name)
                            Spacer()
                            Text(cube.generation?.rawValue ?? "tap to connect")
                                .font(.brand(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.muted)
                        }
                    }
                    .buttonStyle(BigButtonStyle(isProminent: false))
                }
            }
            .pointedAt(.cubeList, by: narrator)

            // Always a way on that needs no cube at all.
            Button {
                onUseCamera()
            } label: {
                Label("Use the camera instead", systemImage: "camera.fill")
            }
            .buttonStyle(BigButtonStyle(tint: Theme.muted, isProminent: false))
            .pointedAt(.lookAtMyCube, by: narrator)
            .padding(.top, 10)
        }
    }

    /// Say where connecting has got to, and what to do about it.
    ///
    /// All of this used to be written only: "wiggle your cube", "Bluetooth is
    /// off", "tap to connect". A child who cannot read was left looking at a
    /// spinner.
    private func explainWhereWeAre() {
        switch manager.status {
        case .bluetoothOff:
            narrator.explain([
                .init("Bluetooth is turned off, so I can't find your cube."),
                .init("Ask a grown-up to press this button and turn Bluetooth on.",
                      pointingAt: .openSettings),
            ])
        case .unauthorised:
            narrator.explain([
                .init("I'm not allowed to use Bluetooth yet."),
                .init("Ask a grown-up to press this button and let me.", pointingAt: .openSettings),
            ])
        case .idle, .scanning:
            var parts: [Narrator.Part] = [
                .init("Give your cube a wiggle to wake it up. I'll find it and connect by myself."),
            ]
            if manager.discovered.count > 1 {
                parts.append(.init("There's more than one cube here. Press yours.",
                                   pointingAt: .cubeList))
            }
            parts.append(.init("Or, to use the camera instead, press the camera button.",
                               pointingAt: .lookAtMyCube))
            narrator.explain(parts)
        case .connecting:
            narrator.say(manager.isWaitingForItToWake
                         ? "Give your cube a wiggle to wake it up."
                         : "Found it! Connecting to your cube.")
        case .connected:
            if manager.trackedColours != nil {
                explainIfThereIsAPicture()
            } else {
                narrator.say("Connected! Give your cube a wiggle so it tells me what it looks like.")
            }
        case .unsupported, .failed:
            narrator.explain([
                .init("I couldn't talk to that cube."),
                .init("Press the camera button, and show me your cube instead.",
                      pointingAt: .lookAtMyCube),
            ])
        }
    }

    /// What the cube says it looks like, and one way on.
    ///
    /// It used to ask the child to solve their cube and say so before it would
    /// show them anything, which is a strange thing to ask of someone who came
    /// here to have it solved. The cube reports its own position the moment it
    /// connects, so that is what goes on screen.
    private var connectedControls: some View {
        VStack(spacing: 12) {
            if let colours = manager.trackedColours {
                Text("Hold your cube with yellow on top and green facing you. "
                     + "This is what it tells me it looks like.")
                    .font(.brand(size: 15, weight: .medium))
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)

                CubeNetView(colours: colours, width: 260)

                Button { onUseCube() } label: {
                    Label("Solve this", systemImage: "play.fill")
                }
                .buttonStyle(BigButtonStyle(tint: Theme.done))
                .pointedAt(.solveThis, by: narrator)

                // The cube knows which way it has been turned but not what
                // colour anything is, so when its idea of itself is wrong the
                // camera is the only thing that can correct it. Saying "it's
                // solved" was the only way out of here, which is no use at all
                // when the cube in your hand is scrambled.
                Button {
                    onUseCamera()
                } label: {
                    Label("My cube looks different", systemImage: "camera.fill")
                }
                .buttonStyle(BigButtonStyle())
                .pointedAt(.looksDifferent, by: narrator)

                Button { onCalibrateSolved() } label: {
                    Label("Or it's solved right now", systemImage: "checkmark.seal.fill")
                }
                .buttonStyle(BigButtonStyle(isProminent: false))
                .pointedAt(.solvedNow, by: narrator)
            } else {
                ProgressView()
                    .tint(Theme.attention)
                Text("Asking your cube where it is. Give it a wiggle.")
                    .font(.brand(size: 15, weight: .medium))
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
            }

            if showsGrownUpThings { grownUpThings }

        }
    }

    /// The things only a grown-up needs: checking the cube's turns, the move
    /// log, and disconnecting. They sat among the child's buttons, where one
    /// wrong press took the cube away or opened a test they could not follow.
    /// Now they are behind the gear at the top, which has to be held down.
    private var grownUpThings: some View {
        VStack(spacing: 12) {
            Text("For grown-ups")
                .font(.brand(size: 14, weight: .bold))
                .foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)

            Button("Check my turns") { isChecking = true }
                .buttonStyle(BigButtonStyle(tint: Theme.muted, isProminent: false))

            moveLog

            Button("Disconnect") { manager.disconnect() }
                .buttonStyle(BigButtonStyle(tint: Theme.muted, isProminent: false))
        }
    }


    /// The move log: on, off, and what it has caught.
    ///
    /// A check screen can only test the cube against a script. This catches
    /// what happens in a real solve, where the plan, the way it is being held
    /// and the child all get a say — which is the only place "it turns the
    /// wrong side" has ever been reported.
    private var moveLog: some View {
        VStack(spacing: 10) {
            Toggle(isOn: $manager.isLogging) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep a move log")
                        .font(.brand(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Writes down every turn and every change of step, "
                         + "to send when something goes wrong.")
                        .font(.brand(size: 13, weight: .medium))
                        .foregroundStyle(Theme.muted)
                }
            }
            .tint(Theme.done)

            if manager.isLogging, !manager.turnLog.isEmpty {
                Button {
                    isReadingTheLog = true
                } label: {
                    Label("Read the log (\(manager.turnLog.entries.count) turns, "
                          + "\(manager.turnLog.moments.count) changes)",
                          systemImage: "list.bullet.rectangle")
                }
                .buttonStyle(BigButtonStyle(isProminent: false))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    /// Once the cube's picture is up, say what each button does, pointing at
    /// each one.
    private func explainIfThereIsAPicture() {
        guard manager.isConnected, manager.trackedColours != nil else { return }
        narrator.explain([
            .init("This is what your cube tells me it looks like."),
            .init("If it looks like your cube, press the green play button.",
                  pointingAt: .solveThis),
            .init("If it looks different, press the blue camera button, and show me.",
                  pointingAt: .looksDifferent),
            .init("If your cube is solved right now, press the button with the tick.",
                  pointingAt: .solvedNow),
        ])
    }

    private var statusTitle: String {
        switch manager.status {
        case .idle: return "Looking for cubes"
        case .bluetoothOff: return "Bluetooth is off"
        case .unauthorised: return "Bluetooth isn't allowed"
        case .scanning: return "Looking for cubes"
        case .connecting(let name): return "Connecting to \(name)"
        case .connected(let name): return "Connected to \(name)"
        case .unsupported: return "Cube not supported"
        case .failed: return "Something went wrong"
        }
    }

    private var statusDetail: String {
        switch manager.status {
        case .bluetoothOff:
            return "Turn Bluetooth on in Settings, then come back."
        case .unauthorised:
            return "Let NoobCube use Bluetooth in Settings to connect your cube."
        case .connected:
            return manager.hasSaidWhatItLooksLike
                ? "Turn your cube and I'll follow along."
                : "Waiting for your cube to say where it is."
        case .unsupported(let detail), .failed(let detail):
            return detail + " You can still use the camera instead."
        default:
            return "Make sure your smart cube is awake and nearby."
        }
    }
}
