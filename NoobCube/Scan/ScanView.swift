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
                finishedControls
            } else {
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
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(coordinator.isComplete ? "Does this look right?"
                                            : (coordinator.currentStep?.title ?? ""))
                    .font(.system(size: 26, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                Text(coordinator.isComplete
                     ? "Tap any square that's the wrong colour."
                     : "Side \(coordinator.scannedFaceCount + 1) of 6")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.muted)
            }
            Spacer()
            NarratorControls(narrator: narrator)
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
    }

    private var viewfinder: some View {
        ZStack {
            if coordinator.camera.permissionDenied {
                permissionMessage
            } else {
                CameraPreviewView(session: coordinator.camera.session)
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
                    .strokeBorder(Theme.accent, lineWidth: 3)
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
                    .stroke(Theme.success, style: StrokeStyle(lineWidth: 5, lineCap: .round))
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
                .font(.system(size: 44))
                .foregroundStyle(Theme.muted)
            Text("NoobCube needs the camera to look at your cube.")
                .multilineTextAlignment(.center)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
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

    private var liveControls: some View {
        VStack(spacing: 12) {
            Text("Hold it still and I'll take it myself.")
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.muted)

            Button("Take this side now") { coordinator.captureCurrentFace() }
                .buttonStyle(BigButtonStyle())

            Button("Start again") { onCancel() }
                .buttonStyle(BigButtonStyle(tint: Theme.muted, isProminent: false))
        }
        .padding(.horizontal, 20)
    }

    private var finishedControls: some View {
        VStack(spacing: 12) {
            if let problem = coordinator.problem {
                Text(problem)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
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
            .buttonStyle(BigButtonStyle(tint: Theme.success))
            .disabled(coordinator.result == nil)
            .opacity(coordinator.result == nil ? 0.5 : 1)

            Button("Look again") { coordinator.begin() }
                .buttonStyle(BigButtonStyle(isProminent: false))
        }
        .padding(.horizontal, 20)
    }
}
