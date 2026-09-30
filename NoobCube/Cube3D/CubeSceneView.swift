import SceneKit
import SwiftUI

/// Puts the SceneKit cube on screen.
struct CubeSceneView: UIViewRepresentable {
    let controller: CubeSceneController
    /// Set to let the cube be turned round with a finger.
    var allowsTurning = false
    /// Set to be told which square was tapped.
    var onTapSticker: ((Int) -> Void)? = nil

    func makeCoordinator() -> Touches { Touches() }

    /// The finger on the cube: a drag turns it, a tap picks a square.
    @MainActor
    final class Touches: NSObject {
        var controller: CubeSceneController?
        var onTapSticker: ((Int) -> Void)?
        private var lastPoint: CGPoint?

        @objc func dragged(_ recogniser: UIPanGestureRecognizer) {
            guard let view = recogniser.view else { return }
            let point = recogniser.translation(in: view)
            switch recogniser.state {
            case .began:
                lastPoint = point
            case .changed:
                let last = lastPoint ?? point
                // A full width of drag is a bit more than half a turn.
                let scale = Float.pi * 1.2 / Float(max(view.bounds.width, 1))
                controller?.turnByDrag(dx: Float(point.x - last.x) * scale,
                                       dy: Float(point.y - last.y) * scale)
                lastPoint = point
            default:
                lastPoint = nil
            }
        }

        @objc func tapped(_ recogniser: UITapGestureRecognizer) {
            guard let view = recogniser.view as? SCNView, let controller else { return }
            let point = recogniser.location(in: view)
            for hit in view.hitTest(point, options: [.searchMode: SCNHitTestSearchMode.closest.rawValue]) {
                if let index = controller.stickerIndex(of: hit.node) {
                    onTapSticker?(index)
                    return
                }
            }
        }
    }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = controller.scene
        view.backgroundColor = .clear
        view.isOpaque = false
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60
        // SceneKit only runs SCNActions while the view is playing, and the cube
        // is animated constantly, so it stays playing.
        view.rendersContinuously = true
        view.isPlaying = true
        // The app drives the camera through the folding intro, so SceneKit's own
        // camera control is left off to avoid the two fighting.
        view.allowsCameraControl = false
        view.autoenablesDefaultLighting = false

        let touches = context.coordinator
        touches.controller = controller
        touches.onTapSticker = onTapSticker
        if allowsTurning {
            view.addGestureRecognizer(UIPanGestureRecognizer(
                target: touches, action: #selector(Touches.dragged(_:))))
        }
        if onTapSticker != nil {
            view.addGestureRecognizer(UITapGestureRecognizer(
                target: touches, action: #selector(Touches.tapped(_:))))
        }
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        if uiView.scene !== controller.scene {
            uiView.scene = controller.scene
        }
        context.coordinator.controller = controller
        context.coordinator.onTapSticker = onTapSticker
    }
}
