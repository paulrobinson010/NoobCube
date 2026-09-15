import SwiftUI

/// The moves of the current stage, with the one to do now called out.
struct MoveStripView: View {
    let moves: [Move]
    let currentIndex: Int

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(moves.enumerated()), id: \.offset) { index, move in
                        chip(for: move, index: index)
                            .id(index)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }
            .onChange(of: currentIndex) { _, newValue in
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }

    private func chip(for move: Move, index: Int) -> some View {
        let isCurrent = index == currentIndex
        let isDone = index < currentIndex

        return VStack(spacing: 2) {
            Text(move.notation)
                .font(.system(size: isCurrent ? 26 : 20, weight: .heavy, design: .rounded))
            Text(move.childLabel)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .opacity(0.85)
        }
        .foregroundStyle(isCurrent ? .white : (isDone ? Theme.muted : .white.opacity(0.75)))
        .frame(minWidth: 74, minHeight: 60)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isCurrent ? Theme.accent : (isDone ? Color.white.opacity(0.06) : Theme.card))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(move.isWholeCubeTurn ? Theme.success : .clear, lineWidth: 2)
        )
        .scaleEffect(isCurrent ? 1.0 : 0.92)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isCurrent)
        .accessibilityLabel(move.spokenInstruction)
    }
}

#Preview {
    MoveStripView(moves: Move.parse("R U R' U' y R U R' U'"), currentIndex: 2)
        .background(Theme.background)
}
