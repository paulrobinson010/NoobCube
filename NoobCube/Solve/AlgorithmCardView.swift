import SwiftUI

/// The move sequence for a stage, which a child can cover up and try to
/// remember.
///
/// This is the point where learning actually happens. The app knows the
/// algorithm perfectly well, so the useful thing it can do is stop showing it —
/// and be there the moment they get stuck.
struct AlgorithmCardView: View {
    let name: String
    let moves: [Move]
    @Binding var covered: Bool
    var onPlay: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(name)
                    .font(.system(size: 20, weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.accent)
                Spacer()
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        covered.toggle()
                    }
                } label: {
                    Label(covered ? "Peek" : "Cover it up",
                          systemImage: covered ? "eye.fill" : "eye.slash.fill")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(.white.opacity(0.12)))
                }
                .accessibilityLabel(covered ? "Show the moves" : "Hide the moves and try from memory")
            }

            ZStack {
                HStack(spacing: 6) {
                    ForEach(Array(moves.enumerated()), id: \.offset) { _, move in
                        Text(move.notation)
                            .font(.system(size: 17, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(minWidth: 34, minHeight: 38)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(.white.opacity(0.10))
                            )
                    }
                }
                .opacity(covered ? 0 : 1)

                if covered {
                    Text("Can you remember it?")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(.white.opacity(0.06))
                        )
                }
            }

            Button(action: onPlay) {
                Label("Watch it once", systemImage: "play.circle.fill")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }
}
