import Combine
import UIKit
import SwiftUI

/// A dozen turns that say what a smart cube means by its own face numbers.
///
/// Six rounds of guessing at this taught one thing: the symptom cannot tell
/// you which of four links is broken, and neither can describing it. This asks
/// the cube directly.
///
/// Every instruction names a **colour**, never a side. "Turn the red face" is
/// the same instruction however the cube is being held, so nothing here
/// depends on which way up it is, on the camera, on a scan, or on any of the
/// machinery being tested. The cube reports a number; the number was the red
/// face. Six of those and the table is complete.
///
/// The cube drawn here has nothing on it but its middles, for the same reason:
/// a scrambled pattern is one more thing that could be wrong, and there is
/// nothing to check it against.
struct SmartCubeCheckView: View {
    @ObservedObject var manager: SmartCubeManager
    @Environment(\.dismiss) private var dismiss

    /// Every face once each way round. The order is deliberate: opposite faces
    /// are never adjacent in it, so turning the wrong one of a pair shows up
    /// as a repeat rather than hiding in the next answer.
    private static let script: [(colour: CubeColour, clockwise: Bool)] = [
        (.white, true), (.red, true), (.green, true),
        (.yellow, true), (.orange, true), (.blue, true),
        (.white, false), (.red, false),
    ]

    private struct Answer: Identifiable {
        let id = UUID()
        let asked: CubeColour
        let clockwise: Bool
        let label: Int
        let sentClockwise: Bool
    }

    @State private var answers: [Answer] = []
    @State private var seen: Int?

    private var step: Int { answers.count }
    private var isDone: Bool { step >= Self.script.count }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if !manager.isConnected {
                        Text("Connect your cube first.")
                            .font(.brand(size: 17, weight: .medium))
                            .foregroundStyle(Theme.muted)
                    } else if isDone {
                        finished
                    } else {
                        asking
                    }
                }
                .padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Cube check")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Start again") { answers = []; seen = nil }
                }
            }
            .onReceive(manager.$lastRawTurn.compactMap { $0 }) { turn in
                record(turn)
            }
        }
    }

    // MARK: - Asking

    private var asking: some View {
        let next = Self.script[step]
        return VStack(spacing: 16) {
            Text("\(step + 1) of \(Self.script.count)")
                .font(.brand(size: 15, weight: .semibold))
                .foregroundStyle(Theme.muted)

            Text("Turn the \(next.colour.displayName.lowercased()) side")
                .font(.brand(size: 28, weight: .heavy))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            Image(systemName: next.clockwise
                  ? "arrow.clockwise" : "arrow.counterclockwise")
                .font(.system(size: 46, weight: .bold))
                .foregroundStyle(swatch(next.colour))

            Text(next.clockwise
                 ? "A quarter turn clockwise, looking straight at that side."
                 : "A quarter turn the other way, looking straight at that side.")
                .font(.brand(size: 15, weight: .medium))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)

            middlesOnly(highlighting: next.colour)

            Text("Hold it however you like — the colour is the instruction.")
                .font(.brand(size: 14, weight: .medium))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .cardBackground()
    }

    /// A cube with nothing on it but its middles.
    private func middlesOnly(highlighting: CubeColour) -> some View {
        let order: [CubeColour] = [.white, .red, .green, .yellow, .orange, .blue]
        return HStack(spacing: 10) {
            ForEach(order, id: \.self) { colour in
                Circle()
                    .fill(swatch(colour))
                    .frame(width: colour == highlighting ? 44 : 26,
                           height: colour == highlighting ? 44 : 26)
                    .overlay(
                        Circle().strokeBorder(.white,
                                              lineWidth: colour == highlighting ? 3 : 0)
                    )
                    .opacity(colour == highlighting ? 1 : 0.35)
            }
        }
        .padding(.vertical, 6)
    }

    private func swatch(_ colour: CubeColour) -> Color {
        let (red, green, blue) = colour.rgb
        return Color(red: red, green: green, blue: blue)
    }

    // MARK: - Recording

    private func record(_ turn: GANProtocol.Turn) {
        guard manager.isConnected, !isDone else { return }
        // The cube re-sends its last few turns, so the same one can arrive
        // twice. Its serial number is what tells them apart.
        guard seen != turn.serial else { return }
        seen = turn.serial
        let asked = Self.script[step]
        answers.append(Answer(asked: asked.colour, clockwise: asked.clockwise,
                              label: turn.label, sentClockwise: turn.clockwise))
    }

    // MARK: - The answer

    private var finished: some View {
        VStack(spacing: 14) {
            Text("That's everything")
                .font(.brand(size: 24, weight: .heavy))
                .foregroundStyle(.white)

            Text(report)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(.black.opacity(0.35)))
                .textSelection(.enabled)

            Button {
                UIPasteboard.general.string = report
            } label: {
                Label("Copy this", systemImage: "doc.on.doc.fill")
            }
            .buttonStyle(BigButtonStyle())
        }
        .frame(maxWidth: .infinity)
        .cardBackground()
    }

    /// What the cube said, and the table it adds up to.
    private var report: String {
        var lines = ["NoobCube cube check"]
        for answer in answers {
            lines.append("asked \(answer.asked.rawValue)"
                         + (answer.clockwise ? "" : " anticlockwise")
                         + "  ->  cube sent #\(answer.label)"
                         + (answer.sentClockwise ? "" : "'"))
        }

        lines.append("")
        var colourForLabel: [Int: Set<CubeColour>] = [:]
        for answer in answers {
            colourForLabel[answer.label, default: []].insert(answer.asked)
        }
        let table = colourForLabel.keys.sorted().map { label -> String in
            let colours = colourForLabel[label] ?? []
            let names = colours.map(\.rawValue).sorted().joined(separator: "/")
            return "#\(label)=\(names)"
        }
        lines.append("table: " + (table.isEmpty ? "nothing" : table.joined(separator: " ")))

        let quarters = answers.filter { $0.clockwise != $0.sentClockwise }
        lines.append("direction: " + (quarters.isEmpty ? "same as ours"
                                      : (quarters.count == answers.count ? "reversed"
                                         : "\(quarters.count) of \(answers.count) reversed")))
        lines.append("faces seen: \(colourForLabel.count) of 6")
        return lines.joined(separator: "\n")
    }
}
