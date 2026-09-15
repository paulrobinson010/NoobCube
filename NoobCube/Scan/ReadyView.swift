import SwiftUI

/// The moment between reading the cube and starting to solve it.
///
/// The flat net folds up into the cube the child is holding, then three centres
/// light up to show the grip: white underneath, yellow on top, and one colour
/// facing them. Everything the solver says afterwards assumes that grip.
struct ReadyView: View {
    let scan: ScannedCube
    let scene: CubeSceneController
    @ObservedObject var narrator: Narrator
    var onStart: () -> Void

    @State private var hasFolded = false

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text(hasFolded ? "Hold it like this" : "Here's your cube")
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
                NarratorControls(narrator: narrator)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)

            CubeSceneView(controller: scene)
                .frame(height: 340)

            if hasFolded {
                gripCard
                    .padding(.horizontal, 20)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            Spacer(minLength: 0)

            Button("Let's solve it!") { onStart() }
                .buttonStyle(BigButtonStyle(tint: Theme.success))
                .padding(.horizontal, 20)
                .padding(.bottom, 18)
                .opacity(hasFolded ? 1 : 0.4)
                .disabled(!hasFolded)
        }
        .background(Theme.background.ignoresSafeArea())
        .onAppear(perform: fold)
    }

    private var gripCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            gripRow(colour: bottomColour, label: "on the bottom")
            gripRow(colour: topColour, label: "on the top")
            gripRow(colour: frontColour, label: "facing you")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    private func gripRow(colour: CubeColour, label: String) -> some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(colour.swiftUIColor)
                .frame(width: 42, height: 42)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.black.opacity(0.35), lineWidth: 1))
            Text("\(colour.displayName) \(label)")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
    }

    private var topColour: CubeColour { scan[Face.U.centreIndex] ?? .yellow }
    private var bottomColour: CubeColour { scan[Face.D.centreIndex] ?? .white }
    private var frontColour: CubeColour { scan[Face.F.centreIndex] ?? .green }

    private func fold() {
        guard !hasFolded else { return }
        scene.foldNetIntoCube(colours: scan.colours) {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                hasFolded = true
            }
            scene.highlightGrip()
            narrator.say("Here's your cube. Hold it with \(bottomColour.spokenName) on the bottom, "
                         + "\(topColour.spokenName) on top, and \(frontColour.spokenName) facing you. "
                         + "Keep holding it that way.")
        }
    }
}
