import SwiftUI
import UIKit

/// Looking at the cube through the camera.
///
/// The flat net above the viewfinder fills in as each side is shown, so the
/// child can watch the app work the cube out. Any square can be tapped to fix a
/// colour the camera got wrong.
struct ScanView: View {
    @ObservedObject var coordinator: ScanCoordinator
    @ObservedObject var narrator: Narrator
    var onReady: (CubeState, Face, ScannedCube) -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            header

            CubeNetView(colours: coordinator.scan.colours,
                        highlightedFace: coordinator.currentStep?.face,
                        pulsingFace: coordinator.currentStep?.face,
                        onTapSticker: coordinator.isComplete
                            ? { coordinator.cycleSticker(at: $0) }
                            : nil)
                .frame(height: 150)
                .padding(.horizontal, 20)

            if coordinator.isComplete {
                // The camera stays on. A side that came out wrong is put right
                // by showing it again, which beats hunting for the squares that
                // are wrong and tapping them one at a time.
                viewfinder
                finishedControls
            } else {
                sideChips
                viewfinder
                liveControls
            }

            Spacer(minLength: 0)
        }
        .background(Theme.background.ignoresSafeArea())
        .onAppear { coordinator.begin() }
        .onDisappear { coordinator.stop() }
        .onChange(of: coordinator.camera.steadiness) { _, _ in
            coordinator.considerAutoCapture()
        }
    }

    // MARK: - Pieces

    private var header: some View {
        ScreenHeader(title: coordinator.isComplete ? "Does this look right?"
                                                   : (coordinator.currentStep?.title ?? ""),
                     subtitle: coordinator.isComplete
                         ? "All six sides"
                         : "Side \(coordinator.scannedFaceCount + 1) of 6",
                     narrator: narrator)
        .padding(.horizontal, 20)
        .padding(.top, 10)
    }

    /// A dot per side, filling in as each one is seen. Order does not matter —
    /// a side is recognised by the colour of its middle sticker — so this is a
    /// checklist rather than a queue.
    private var sideChips: some View {
        HStack(spacing: 10) {
            ForEach(ScanCoordinator.steps, id: \.face) { step in
                let colour = ScanCoordinator.colour(for: step.face)
                let done = coordinator.scan.isFaceScanned(step.face)
                Circle()
                    .fill(colour.swiftUIColor)
                    .frame(width: 26, height: 26)
                    .overlay(
                        Circle().strokeBorder(done ? Theme.done : .white.opacity(0.25),
                                              lineWidth: done ? 3 : 1)
                    )
                    .overlay(
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .black))
                            .foregroundStyle(.black.opacity(0.65))
                            .opacity(done ? 1 : 0)
                    )
                    .opacity(done ? 1 : 0.35)
                    .accessibilityLabel("\(colour.displayName) side \(done ? "done" : "still to do")")
            }
        }
        .padding(.vertical, 2)
    }

    private var viewfinder: some View {
        ZStack {
            if coordinator.camera.permissionDenied {
                permissionMessage
            } else {
                GeometryReader { preview in
                    CameraPreviewView(session: coordinator.camera.session)
                        .onAppear { coordinator.camera.setPreviewSize(preview.size) }
                        .onChange(of: preview.size) { _, size in
                            coordinator.camera.setPreviewSize(size)
                        }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
                guideOverlay
            }
        }
        .frame(height: 300)
        .padding(.horizontal, 20)
    }

    /// The square the child lines the cube up inside, with what the camera
    /// currently thinks each sticker is.
    private var guideOverlay: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height) * 0.62
            let cell = side / 3
            let live = coordinator.livePreview

            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(coordinator.camera.isCubeInFrame
                                  ? Theme.attention : Color.white.opacity(0.35),
                                  lineWidth: 3)
                    .frame(width: side, height: side)

                ForEach(0..<9, id: \.self) { offset in
                    let row = offset / 3
                    let column = offset % 3
                    Circle()
                        .fill(live.indices.contains(offset)
                              ? live[offset].swiftUIColor
                              : Color.white.opacity(0.25))
                        .frame(width: cell * 0.34, height: cell * 0.34)
                        .overlay(Circle().strokeBorder(.black.opacity(0.4), lineWidth: 1))
                        .offset(x: (CGFloat(column) - 1) * cell,
                                y: (CGFloat(row) - 1) * cell)
                }

                // A ring that closes as the cube is held still.
                Circle()
                    .trim(from: 0, to: coordinator.camera.steadiness)
                    .stroke(Theme.done, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: side + 34, height: side + 34)
                    .animation(.easeOut(duration: 0.2), value: coordinator.camera.steadiness)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private var permissionMessage: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.fill")
                .font(.brand(size: 44))
                .foregroundStyle(Theme.muted)
            Text("NoobCube needs the camera to look at your cube.")
                .multilineTextAlignment(.center)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(BigButtonStyle())
        }
        .padding(24)
    }

    /// One line of help under the viewfinder.
    ///
    /// Swapped outright rather than faded: a cross-fade between two sentences
    /// draws both of them, one on top of the other, and this one changes often
    /// enough that the overlap is what you mostly see.
    private var caption: String {
        if coordinator.camera.isStarting || !coordinator.camera.isRunning {
            return "Waking the camera up…"
        }
        if !coordinator.camera.isCubeInFrame {
            return "Hold your cube in front of the camera."
        }
        if coordinator.isStillOnTheSideJustTaken {
            return "Got that one. Turn the cube to the next side."
        }
        return coordinator.camera.settling < 1
            ? "Keep it still while I look…"
            : "Hold it still and I'll take it myself."
    }

    private var liveControls: some View {
        VStack(spacing: 12) {
            Text(caption)
                .font(.brand(size: 16, weight: .medium))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(height: 44)
                .contentTransition(.identity)
                .animation(nil, value: caption)

            Button("Take this side now") { coordinator.captureCurrentFace() }
                .buttonStyle(BigButtonStyle())

            Button("Start again") { onCancel() }
                .buttonStyle(BigButtonStyle(tint: Theme.muted, isProminent: false))
        }
        .padding(.horizontal, 20)
    }

    private var finishedControls: some View {
        VStack(spacing: 12) {
            Text("Something wrong? Hold up that side and take it again, "
               + "or tap any square to fix it.")
                .font(.brand(size: 16, weight: .medium))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)

            if let problem = coordinator.problem {
                Text(problem)
                    .font(.brand(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .cardBackground()
            }

            Button("Yes, that's my cube!") {
                if let result = coordinator.result {
                    onReady(result.state, result.whiteFace, coordinator.scan)
                }
            }
            .buttonStyle(BigButtonStyle(tint: Theme.done))
            .disabled(coordinator.result == nil)
            .opacity(coordinator.result == nil ? 0.5 : 1)

            Button("Take that side again") { coordinator.captureCurrentFace() }
                .buttonStyle(BigButtonStyle(isProminent: false))

            Button("Start the whole thing again") { coordinator.begin() }
                .buttonStyle(BigButtonStyle(tint: Theme.muted, isProminent: false))
        }
        .padding(.horizontal, 20)
    }
}
