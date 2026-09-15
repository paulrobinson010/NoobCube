import SwiftUI

/// Finding and connecting a smart cube.
struct SmartCubeView: View {
    @ObservedObject var manager: SmartCubeManager
    @ObservedObject var narrator: Narrator
    var onUseCube: () -> Void

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
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
            Text(statusDetail)
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.muted)
            if let battery = manager.batteryPercent {
                Label("\(battery)%", systemImage: "battery.100")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.success)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    private var cubeList: some View {
        VStack(spacing: 10) {
            if manager.discovered.isEmpty {
                ProgressView()
                    .tint(Theme.accent)
                    .padding(.top, 20)
                Text("Wiggle your cube to wake it up.")
                    .font(.system(size: 16, weight: .medium, design: .rounded))
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
                        Text(cube.generation.rawValue)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.muted)
                    }
                }
                .buttonStyle(BigButtonStyle(isProminent: false))
            }
        }
    }

    private var connectedControls: some View {
        VStack(spacing: 12) {
            Button("Solve with my smart cube") {
                onUseCube()
            }
            .buttonStyle(BigButtonStyle(tint: Theme.success))
            .disabled(manager.trackedState == nil)

            if manager.trackedState == nil {
                Text("Give the cube a turn so it can tell me what it looks like.")
                    .font(.system(size: 15, weight: .medium, design: .rounded))
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
            return "Turn your cube and I'll follow along — no camera needed."
        case .unsupported(let detail), .failed(let detail):
            return detail + " You can still use the camera instead."
        default:
            return "Make sure your smart cube is awake and nearby."
        }
    }
}
