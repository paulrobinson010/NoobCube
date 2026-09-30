import SwiftUI

/// The scanned cube in 3D, to turn round with a finger and paint by hand.
///
/// The flat map is how the app thinks of a cube, not how a child does. Here it
/// is the cube they are holding: drag it round until the side matches the one
/// in their hand, pick a colour, and tap the square that came out wrong.
struct CubeEditor3DView: View {
    @ObservedObject var coordinator: ScanCoordinator

    @Environment(\.dismiss) private var dismiss
    @State private var scene = CubeSceneController()
    @State private var brush: CubeColour = .white

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Text("Drag to turn it round. Pick a colour, then tap a square to paint it.")
                    .font(.brand(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)

                CubeSceneView(controller: scene, allowsTurning: true) { index in
                    guard index % 9 != 4, let face = Face(rawValue: index / 9),
                          coordinator.canEdit(face) else { return }
                    coordinator.setSticker(at: index, to: brush)
                }
                .frame(maxWidth: .infinity, minHeight: 220, maxHeight: .infinity)
                .pointedAt(.paintHere, by: coordinator.narrator)

                if let problem = coordinator.problem, coordinator.isComplete {
                    Text(problem)
                        .font(.brand(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 20)
                }

                PaintPalette(brush: $brush)
                    .pointedAt(.palette, by: coordinator.narrator)

                Button {
                    scene.resetTurn()
                } label: {
                    Label("Turn it back", systemImage: "arrow.counterclockwise")
                        .font(.brand(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                }
                .padding(.bottom, 12)
            }
            .padding(.top, 8)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Your cube in 3D")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                scene.stopIdleSpin()
                scene.reset(to: coordinator.scan.colours)
                coordinator.narrator.explain([
                    .init("Drag the cube with your finger to turn it round.", pointingAt: .paintHere),
                    .init("Tap a colour down here,", pointingAt: .palette),
                    .init("then tap a square on the cube to paint it.", pointingAt: .paintHere),
                ])
            }
            .onChange(of: coordinator.scan) { _, painted in
                scene.setColours(painted.colours)
            }
        }
    }
}
