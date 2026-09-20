import Combine
import SwiftUI
import UIKit

/// Turn this, then that — and watch which side the app thinks you turned.
///
/// Every instruction names a **colour**, never a side of the screen. "Turn the
/// red face" is the same instruction however the cube is being held, so nothing
/// here depends on which way up it is, on a scan, or on any of the machinery
/// being checked.
///
/// The cube on screen has nothing on it but its middles, and it turns as the
/// app reads each turn. That is the whole point: with only the middles coloured
/// there is no pattern to puzzle over, so which face spins is plain to see. Ask
/// for red, watch orange go round, and the fault is in front of you rather than
/// in a log.
struct SmartCubeCheckView: View {
    @ObservedObject var manager: SmartCubeManager
    @Environment(\.dismiss) private var dismiss

    /// Every face once each way round. Opposite faces are never next to each
    /// other in the order, so turning the wrong one of a pair shows up as a
    /// repeat rather than hiding in the next answer.
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
        /// What the app made of it, once its own machinery has had a go.
        let readAs: Move?
    }

    @State private var answers: [Answer] = []
    @State private var seen: Int?
    @State private var scene = CubeSceneController()

    private var step: Int { answers.count }
    private var isDone: Bool { step >= Self.script.count }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if !manager.isConnected {
                        Text("Connect your cube first.")
                            .font(.brand(size: 17, weight: .medium))
                            .foregroundStyle(Theme.muted)
                    } else {
                        CubeSceneView(controller: scene)
                            .frame(height: 240)
                        if isDone { finished } else { asking }
                        if let last = answers.last { whatHappened(last) }
                    }
                }
                .padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Turn check")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Start again") { restart() }
                }
            }
            .onAppear { scene.reset(to: Self.middlesOnly) }
            .onReceive(manager.$lastRawTurn.compactMap { $0 }) { record($0) }
        }
    }

    // MARK: - A cube with nothing on it but its middles

    /// Grey everywhere, six colours in the six centres. Nothing to read but
    /// which side is going round.
    private static let middlesOnly: [CubeColour?] = {
        var colours = [CubeColour?](repeating: nil, count: 54)
        for face in Face.allCases {
            colours[face.centreIndex] = CubeColour.onTheCubesOwnFace(face)
        }
        return colours
    }()

    // MARK: - Asking

    private var asking: some View {
        let next = Self.script[step]
        return VStack(spacing: 12) {
            Text("\(step + 1) of \(Self.script.count)")
                .font(.brand(size: 15, weight: .semibold))
                .foregroundStyle(Theme.muted)

            HStack(spacing: 12) {
                Circle()
                    .fill(swatch(next.colour))
                    .frame(width: 44, height: 44)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 3))
                Text("Turn the \(next.colour.displayName.lowercased()) side")
                    .font(.brand(size: 24, weight: .heavy))
                    .foregroundStyle(.white)
                Image(systemName: next.clockwise
                      ? "arrow.clockwise" : "arrow.counterclockwise")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(Theme.attention)
            }

            Text(next.clockwise
                 ? "A quarter turn clockwise, looking straight at that side."
                 : "A quarter turn the other way, looking straight at that side.")
                .font(.brand(size: 14, weight: .medium))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)

            Text("Hold it however you like — the colour is the instruction.")
                .font(.brand(size: 13, weight: .medium))
                .foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity)
        .cardBackground()
    }

    /// The last turn, side by side: what was asked for, what span.
    private func whatHappened(_ answer: Answer) -> some View {
        HStack(spacing: 14) {
            VStack(spacing: 4) {
                Text("you turned").font(.brand(size: 13, weight: .medium))
                    .foregroundStyle(Theme.muted)
                Circle().fill(swatch(answer.asked)).frame(width: 34, height: 34)
            }
            Image(systemName: "arrow.right")
                .foregroundStyle(Theme.muted)
            VStack(spacing: 4) {
                Text("it turned").font(.brand(size: 13, weight: .medium))
                    .foregroundStyle(Theme.muted)
                if let spun = spunColour(answer) {
                    Circle().fill(swatch(spun)).frame(width: 34, height: 34)
                } else {
                    Text("—").foregroundStyle(Theme.muted)
                }
            }
            if let spun = spunColour(answer), spun != answer.asked {
                Text("not the same")
                    .font(.brand(size: 14, weight: .bold))
                    .foregroundStyle(Theme.attention)
            }
        }
        .frame(maxWidth: .infinity)
        .cardBackground()
    }

    /// Which colour the app actually spun, in the cube's own frame.
    private func spunColour(_ answer: Answer) -> CubeColour? {
        guard let move = answer.readAs, let face = Face(rawValue: faceIndex(move.base)) else {
            return nil
        }
        return CubeColour.onTheCubesOwnFace(face)
    }

    private func faceIndex(_ base: MoveBase) -> Int {
        Face.allCases.firstIndex { $0.letter == base.rawValue } ?? 0
    }

    private func swatch(_ colour: CubeColour) -> Color {
        let (red, green, blue) = colour.rgb
        return Color(red: red, green: green, blue: blue)
    }

    // MARK: - Recording

    private func restart() {
        answers = []
        seen = nil
        scene.reset(to: Self.middlesOnly)
    }

    private func record(_ turn: GANProtocol.Turn) {
        guard manager.isConnected, !isDone else { return }
        // These cubes re-send their last few turns, so the same one can arrive
        // twice. Its serial number is what tells them apart.
        guard seen != turn.serial else { return }
        seen = turn.serial

        let asked = Self.script[step]
        let read = manager.dialect.move(forLabel: turn.label, clockwise: turn.clockwise)
        answers.append(Answer(asked: asked.colour, clockwise: asked.clockwise,
                              label: turn.label, sentClockwise: turn.clockwise,
                              readAs: read))
        // Spin it, so which face the app believes moved is a thing you watch
        // rather than a thing you read.
        if let read { scene.animate(read, duration: 0.35) {} }
    }

    // MARK: - The answer

    private var finished: some View {
        VStack(spacing: 12) {
            Text("That's everything")
                .font(.brand(size: 22, weight: .heavy))
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

    /// What the cube said, what the app made of it, and the table it adds up to.
    private var report: String {
        var lines = ["NoobCube turn check"]
        for answer in answers {
            let spun = spunColour(answer).map(\.rawValue) ?? "nothing"
            lines.append("asked \(answer.asked.rawValue)"
                         + (answer.clockwise ? "" : " anticlockwise")
                         + "  ->  cube sent #\(answer.label)"
                         + (answer.sentClockwise ? "" : "'")
                         + "  ->  app turned \(spun)"
                         + (answer.readAs.map { " (\($0.notation))" } ?? ""))
        }

        lines.append("")
        var colourForLabel: [Int: Set<CubeColour>] = [:]
        for answer in answers {
            colourForLabel[answer.label, default: []].insert(answer.asked)
        }
        let table = colourForLabel.keys.sorted().map { label in
            "#\(label)=" + (colourForLabel[label] ?? []).map(\.rawValue).sorted()
                .joined(separator: "/")
        }
        lines.append("table: " + (table.isEmpty ? "nothing" : table.joined(separator: " ")))

        let wrongWay = answers.filter { $0.clockwise != $0.sentClockwise }
        lines.append("direction: " + (wrongWay.isEmpty ? "same as ours"
                                      : "\(wrongWay.count) of \(answers.count) reversed"))
        let spunWrong = answers.filter { spunColour($0) != $0.asked }
        lines.append("app turned the wrong side: \(spunWrong.count) of \(answers.count)")
        lines.append("faces seen: \(colourForLabel.count) of 6")
        return lines.joined(separator: "\n")
    }
}
