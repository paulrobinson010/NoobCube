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

    /// The side open for fixing by hand, if any.
    @State private var editing: EditedSide?
    /// The whole cube open in 3D, to turn round and fix.
    @State private var showing3D = false

    private struct EditedSide: Identifiable {
        let face: Face
        var id: Int { face.rawValue }
    }

    var body: some View {
        VStack(spacing: 10) {
            header

            // The map, then the camera, then what to press. Nothing scrolls and
            // nothing is cut off: the map is drawn at a size it is told, so the
            // camera gets whatever is left over and always gets all of it.
            CubeNetView(colours: coordinator.scan.colours,
                        width: coordinator.isComplete ? 320 : 232,
                        highlightedFace: coordinator.currentStep?.face,
                        pulsingFace: coordinator.currentStep?.face,
                        // Tapping a side that is in opens it big, to paint its
                        // squares by hand or take it again — during the scan as
                        // well as after.
                        onTapSticker: { index in
                            guard let face = Face(rawValue: index / 9),
                                  coordinator.canEdit(face) else { return }
                            editing = EditedSide(face: face)
                        },
                        doubtful: coordinator.doubtful)
                .pointedAt(.scanMap, by: narrator)

            if coordinator.scannedFaceCount > 0 {
                HStack(spacing: 10) {
                    Text("Something wrong? Tap that side to fix it.")
                        .font(.brand(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Button {
                        showing3D = true
                    } label: {
                        Label("3D", systemImage: "cube.fill")
                            .font(.brand(size: 13, weight: .bold))
                            .foregroundStyle(Theme.ink)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Theme.attention))
                    }
                    .accessibilityLabel("See the cube in 3D and fix it there")
                }
                .padding(.horizontal, 20)
            }

            // One viewfinder, in one place, whether the scan is finished or
            // not. Having it inside both halves of an if meant SwiftUI counted
            // them as two different views and pulled the camera preview layer
            // down and built a new one the moment the last side went in.
            //
            // It stays on afterwards on purpose: a side that came out wrong is
            // put right by showing it again.
            viewfinder

            if coordinator.isComplete { finishedControls } else { liveControls }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.background.ignoresSafeArea())
        .onAppear { coordinator.begin() }
        .onDisappear { coordinator.stop() }
        .sheet(item: $editing, onDismiss: { coordinator.isPaused = false }) { side in
            SideEditorView(coordinator: coordinator, face: side.face)
                .onAppear { coordinator.isPaused = true }
        }
        .fullScreenCover(isPresented: $showing3D, onDismiss: { coordinator.isPaused = false }) {
            CubeEditor3DView(coordinator: coordinator)
                .onAppear { coordinator.isPaused = true }
        }
    }

    // MARK: - Pieces

    private var header: some View {
        ScreenHeader(title: coordinator.isComplete ? "Does this look right?"
                         : coordinator.isTakingAnyAgain ? "Show me the side again"
                         : (coordinator.currentStep?.title ?? ""),
                     subtitle: coordinator.isComplete
                         ? "All six sides"
                         : "Side \(coordinator.scannedFaceCount + 1) of 6",
                     narrator: narrator,
                     onHome: onCancel)
        .padding(.horizontal, 20)
        .padding(.top, 10)
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
        // Takes whatever the map and the buttons have not, so it is as big as
        // it can be and always whole.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) {
            // How to hold it for this side, on screen the whole time it is
            // being looked for.
            if !coordinator.isComplete, !coordinator.isTakingAnyAgain,
               let step = coordinator.currentStep {
                HoldGuideView(front: ScanCoordinator.colour(for: step.face), top: step.upColour)
                    .padding(.top, 10)
                    .padding(.horizontal, 10)
            }
        }
        .overlay(alignment: .bottom) { cameraCaption }
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
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
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Label("Let NoobCube use the camera", systemImage: "gearshape.fill")
            }
            .buttonStyle(BigButtonStyle())
            .pointedAt(.openSettings, by: narrator)
        }
        .padding(24)
        // Said as well as written: a child who pressed "Don't Allow" cannot
        // read either the question they answered or this.
        .onAppear {
            narrator.explain([
                .init("I'm not allowed to use the camera, so I can't see your cube."),
                .init("Ask a grown-up to press this button and let me.", pointingAt: .openSettings),
            ])
        }
    }

    /// The line of help, written on the picture.
    ///
    /// It had a row of its own under the camera, which is a row the camera
    /// could have had. There is plenty of dark sky in a viewfinder.
    private var cameraCaption: some View {
        Text(caption)
            .font(.brand(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            // The longest of these runs to two lines on a big phone and three
            // on a small one; at two it lost its end.
            .lineLimit(3)
            .minimumScaleFactor(0.85)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(.black.opacity(0.55))
            .contentTransition(.identity)
            .animation(nil, value: caption)
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
            return "Got that one. Turn the cube, or take it again if it looks wrong."
        }
        return coordinator.camera.settling < 1
            ? "Keep it still while I look…"
            : "Hold it still and I'll take it myself."
    }

    private var liveControls: some View {
        VStack(spacing: 10) {
            Button("Take this side now") { coordinator.captureCurrentFace() }
                .buttonStyle(BigButtonStyle())

            HStack(spacing: 0) {
                if coordinator.hasTakenASide {
                    smallButton("Take that one again") { coordinator.takeThatSideAgain() }
                }
                // Starts the scan again — it used to go home, whatever it said.
                // Home is the house at the top.
                smallButton("Start again") { coordinator.begin() }
                    .pointedAt(.restartScan, by: narrator)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 4)
    }

    private var finishedControls: some View {
        VStack(spacing: 10) {
            if let problem = coordinator.problem {
                Text(problem)
                    .font(.brand(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                            .fill(Theme.card))
            }

            Button {
                if let result = coordinator.result {
                    onReady(result.state, result.whiteFace, coordinator.scan)
                }
            } label: {
                Label("Yes, that's my cube!", systemImage: "checkmark")
            }
            .buttonStyle(BigButtonStyle(tint: Theme.done))
            .pointedAt(.thatsMyCube, by: narrator)
            .disabled(coordinator.result == nil)
            .opacity(coordinator.result == nil ? 0.5 : 1)

            HStack(spacing: 0) {
                smallButton("Take a side again") { coordinator.letMeTakeASideAgain() }
                    .pointedAt(.retakeSide, by: narrator)
                smallButton("Start over") { coordinator.begin() }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 4)
    }

    /// The ways out, small and side by side, so they take one row between them
    /// rather than one each.
    private func smallButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.brand(size: 15, weight: .semibold))
            .foregroundStyle(Theme.muted)
            .frame(maxWidth: .infinity, minHeight: 40)
            .contentShape(Rectangle())
    }

}
