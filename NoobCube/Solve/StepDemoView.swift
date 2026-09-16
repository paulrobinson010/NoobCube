import SwiftUI

/// A small cube beside the big one, playing the whole set of moves on a loop.
///
/// It replaces "watch it first". Choosing between seeing it done and doing it
/// was a choice a five year old should never have had to make: the demo now
/// runs the whole time, next to the cube they are working on, so the only
/// button left on the screen is the one that moves them forward.
struct StepDemoView: View {
    let moves: [Move]
    let colours: [CubeColour?]

    @StateObject private var demo = StepDemo()

    /// What the demo is showing. When either part changes it starts again from
    /// the beginning, which is what a new step needs.
    private struct Showing: Equatable {
        let moves: [Move]
        let colours: [CubeColour?]
    }

    var body: some View {
        VStack(spacing: 0) {
            CubeSceneView(controller: demo.scene)
                .frame(width: 104, height: 92)
            Text("watch")
                .font(.brand(size: 11, weight: .bold))
                .foregroundStyle(Theme.muted)
                .padding(.bottom, 6)
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Theme.card.opacity(0.9))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 1)
        )
        .accessibilityLabel("A small cube showing the whole set of moves over and over")
        .task(id: Showing(moves: moves, colours: colours)) {
            await demo.roll(moves, from: colours)
        }
    }
}

/// Drives the little cube round and round.
@MainActor
final class StepDemo: ObservableObject {
    let scene = CubeSceneController()

    /// Long enough to follow at this size, and slower than the big cube's.
    private static let turn = 0.40
    /// A moment to take in where it starts, and where it ended up.
    private static let openingBeat = 0.75
    private static let closingBeat = 1.0

    /// Play the moves, pause, start again — until the step changes or the view
    /// goes away, either of which cancels the task this runs in.
    func roll(_ moves: [Move], from colours: [CubeColour?]) async {
        guard !moves.isEmpty, colours.count == 54 else { return }
        while !Task.isCancelled {
            scene.reset(to: colours)
            guard await beat(Self.openingBeat) else { return }
            for move in moves {
                // Fired off rather than awaited: a demo that is interrupted
                // half way through is simply reset next time round, and
                // nothing is left waiting on an animation that stopped when
                // the view it was drawn in went away.
                scene.animate(move, duration: Self.turn) {}
                guard await beat(Self.turn + 0.06) else { return }
            }
            guard await beat(Self.closingBeat) else { return }
        }
    }

    /// A moment to look at the cube. False once the demo has been stopped.
    private func beat(_ seconds: Double) async -> Bool {
        do {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return true
        } catch {
            return false
        }
    }
}
