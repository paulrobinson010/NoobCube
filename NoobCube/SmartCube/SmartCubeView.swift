import SwiftUI

/// Finding and connecting a smart cube.
struct SmartCubeView: View {
    @ObservedObject var manager: SmartCubeManager
    @ObservedObject var narrator: Narrator
    var onUseCube: () -> Void
    var onUseCamera: () -> Void
    var onCalibrateSolved: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                statusCard

                if manager.isConnected {
                    connectedControls
                } else {
                    cubeList
                }

                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Smart cube")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .onAppear { manager.startScanning() }
        .onDisappear { manager.stopScanning() }
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
            if manager.discovered.isEmpty {
                ProgressView()
                    .tint(Theme.attention)
                    .padding(.top, 20)
                Text("Wiggle your cube to wake it up.")
                    .font(.brand(size: 16, weight: .medium))
                    .foregroundStyle(Theme.muted)
            }
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

                Button("Solve this") { onUseCube() }
                    .buttonStyle(BigButtonStyle(tint: Theme.done))

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

                Button("Or it's solved right now") { onCalibrateSolved() }
                    .buttonStyle(BigButtonStyle(isProminent: false))
            } else {
                ProgressView()
                    .tint(Theme.attention)
                Text("Asking your cube where it is. Give it a wiggle.")
                    .font(.brand(size: 15, weight: .medium))
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
            }

            Button("Disconnect") { manager.disconnect() }
                .buttonStyle(BigButtonStyle(tint: Theme.muted, isProminent: false))
        }
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
