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
        if answered == 0 { return "Tap the colour you turned, and this will say where the fault is" }
        if cube > held { return "The cube's own face numbers are what is wrong" }
        if held > 0 { return "The cube is right; the app renames the side wrongly" }
        if right > 0 { return "Every turn you answered came out right" }
        return "Nothing to go on yet"
    }
}

/// The one question the app cannot answer for itself, asked in the smallest
/// way it can be: six squares, tap the one you just turned.
///
/// Only on screen while the log is being kept. It is there for the grown-up
/// watching, and a five year old should not have to see it the rest of the
/// time.
struct TurnLogStrip: View {
    @ObservedObject var manager: SmartCubeManager
    var onTurned: (CubeColour) -> Void

    @State private var showingLog = false

    var body: some View {
        HStack(spacing: 8) {
            Text(waiting == nil ? "turn your cube" : "you turned")
                .font(.brand(size: 13, weight: .bold))
                .foregroundStyle(Theme.muted)

            ForEach(CubeColour.allCases) { colour in
                Button {
                    onTurned(colour)
                } label: {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(colour.swiftUIColor)
                        .frame(width: 26, height: 26)
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(.black.opacity(0.35), lineWidth: 1))
                        .opacity(waiting == nil ? 0.3 : 1)
                }
                .buttonStyle(.plain)
                .disabled(waiting == nil)
                .accessibilityLabel("I turned \(colour.displayName)")
            }

            Spacer(minLength: 0)

            Button {
                showingLog = true
            } label: {
                Label("\(manager.turnLog.entries.count)", systemImage: "list.bullet.rectangle")
                    .font(.brand(size: 13, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.attention)
            .accessibilityLabel("Open the move log")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(.black.opacity(0.3)))
        .sheet(isPresented: $showingLog) { TurnLogView(manager: manager) }
    }

    /// The newest turn nobody has said a colour for.
    private var waiting: TurnLog.Entry? { manager.turnLog.waitingForAnAnswer }
}
