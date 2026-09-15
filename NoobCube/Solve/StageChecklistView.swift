import SwiftUI

/// The whole solve as a list of ticks.
///
/// A child needs to see that this is a journey with an end, and where they are
/// on it. Steps already done keep their tick, which is the point: the cube is
/// not one enormous puzzle, it is eight small ones.
struct StageChecklistStrip: View {
    let stages: [SolveStage]
    let currentKind: SolveStage.Kind?
    var onOpen: () -> Void

    private var visible: [SolveStage] {
        stages.filter { $0.kind != .hold }
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 6) {
                ForEach(visible) { stage in
                    let state = state(of: stage)
                    Capsule()
                        .fill(colour(for: state))
                        .frame(height: 8)
                        .overlay(
                            Capsule().strokeBorder(.white.opacity(state == .current ? 0.9 : 0),
                                                   lineWidth: 1.5)
                        )
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Step list. Tap to see all the steps.")
    }

    private enum State { case done, current, todo }

    private func state(of stage: SolveStage) -> State {
        guard let currentKind else { return .done }
        if stage.kind == currentKind { return .current }
        return stage.kind.step < currentKind.step ? .done : .todo
    }

    private func colour(for state: State) -> Color {
        switch state {
        case .done: return Theme.success
        case .current: return Theme.accent
        case .todo: return .white.opacity(0.14)
        }
    }
}

/// The full list, opened from the strip.
struct StageChecklistSheet: View {
    let stages: [SolveStage]
    let currentKind: SolveStage.Kind?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(stages.filter { $0.kind != .hold }) { stage in
                        row(for: stage)
                    }
                }
                .padding(20)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("All the steps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func row(for stage: SolveStage) -> some View {
        let isCurrent = stage.kind == currentKind
        let isDone = (currentKind.map { stage.kind.step < $0.step }) ?? true

        return HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(isDone ? Theme.success : (isCurrent ? Theme.accent : Color.white.opacity(0.1)))
                    .frame(width: 36, height: 36)
                if isDone {
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(.black.opacity(0.7))
                } else {
                    Text("\(stage.kind.step - 1)")
                        .font(.system(size: 16, weight: .black, design: .rounded))
                        .foregroundStyle(isCurrent ? .black.opacity(0.75) : .white.opacity(0.65))
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(stage.kind.shortName)
                    .font(.system(size: 19, weight: .heavy, design: .rounded))
                    .foregroundStyle(isCurrent ? Theme.accent : .white)
                Text(stage.kind.why)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(isCurrent ? Color.white.opacity(0.07) : Color.clear)
        )
    }
}
