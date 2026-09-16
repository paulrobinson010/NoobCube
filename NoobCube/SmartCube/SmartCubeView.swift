import SwiftUI

/// Finding and connecting a smart cube.
struct SmartCubeView: View {
    @ObservedObject var manager: SmartCubeManager
    @ObservedObject var narrator: Narrator
    var onUseCube: () -> Void
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

                details

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

    private var connectedControls: some View {
        VStack(spacing: 12) {
            Text("A smart cube knows which way you turned it, but not what "
                 + "colour anything is. So it needs telling where it's starting from.")
                .font(.brand(size: 15, weight: .medium))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)

            if manager.isCalibrated {
                Label("Following your cube", systemImage: "checkmark.circle.fill")
                    .font(.brand(size: 17, weight: .bold))
                    .foregroundStyle(Theme.done)

                Button("Solve from here") { onUseCube() }
                    .buttonStyle(BigButtonStyle(tint: Theme.done))
            } else {
                Button("My cube is solved right now") { onCalibrateSolved() }
                    .buttonStyle(BigButtonStyle())

                Text("Or show it to the camera — after a scan it'll follow along by itself.")
                    .font(.brand(size: 14, weight: .medium))
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
            }

            Button("Disconnect") { manager.disconnect() }
                .buttonStyle(BigButtonStyle(tint: Theme.muted, isProminent: false))
        }
    }

    /// What the app saw while connecting, so a cube it cannot read can be
    /// reported with enough detail to add support for it.
    @ViewBuilder
    private var details: some View {
        if !manager.diagnostics.isEmpty {
            DisclosureGroup("What I saw") {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(manager.diagnostics.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.muted)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
            }
            .font(.brand(size: 15, weight: .semibold))
            .tint(Theme.attention)
            .cardBackground()
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
            return "Turn your cube and I'll follow along — no camera needed."
        case .unsupported(let detail), .failed(let detail):
            return detail + " You can still use the camera instead."
        default:
            return "Make sure your smart cube is awake and nearby."
        }
    }
}
