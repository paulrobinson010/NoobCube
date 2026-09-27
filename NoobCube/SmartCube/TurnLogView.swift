import SwiftUI
import UIKit

/// The move log, written out to be copied and read somewhere with a keyboard.
struct TurnLogView: View {
    @ObservedObject var manager: SmartCubeManager

    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    verdict
                    Text(manager.turnLog.report)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12)
                            .fill(.black.opacity(0.35)))
                        .textSelection(.enabled)

                    Button {
                        UIPasteboard.general.string = manager.turnLog.report
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy the whole log",
                              systemImage: copied ? "checkmark.circle.fill" : "doc.on.doc.fill")
                    }
                    .buttonStyle(BigButtonStyle())

                    Button("Start a fresh log") {
                        manager.clearTheLog()
                        copied = false
                    }
                    .buttonStyle(BigButtonStyle(tint: Theme.muted, isProminent: false))
                }
                .padding(16)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Move log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// What the log adds up to, before anyone reads a line of it.
    ///
    /// The whole point of asking which colour was turned is that it settles
    /// where the fault is, so the log says so outright rather than leaving it
    /// to be worked out from a table.
    private var verdict: some View {
        let counts = manager.turnLog.countsByVerdict
        let cube = counts[.cubeNamedTheWrongFace] ?? 0
        let held = counts[.heldWrongWayRound] ?? 0
        let right = counts[.rightAllTheWay] ?? 0
        let answered = manager.turnLog.entries.filter { $0.turnedByHand != nil }.count

        return VStack(alignment: .leading, spacing: 8) {
            Text(headline(cube: cube, held: held, right: right, answered: answered))
                .font(.brand(size: 20, weight: .heavy))
                .foregroundStyle(cube + held == 0 ? Theme.done : Theme.attention)
            ForEach(manager.turnLog.summaryLines, id: \.self) { line in
                Text(line)
                    .font(.brand(size: 14, weight: .medium))
                    .foregroundStyle(Theme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    private func headline(cube: Int, held: Int, right: Int, answered: Int) -> String {
        if answered == 0 { return "Every turn and every change of step, in order" }
        if cube > held { return "The cube's own face numbers are what is wrong" }
        if held > 0 { return "The cube is right; the app renames the side wrongly" }
        if right > 0 { return "Every turn you answered came out right" }
        return "Nothing to go on yet"
    }
}
