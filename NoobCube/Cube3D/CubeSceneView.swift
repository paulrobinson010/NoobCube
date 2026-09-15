import SceneKit
import SwiftUI

/// Puts the SceneKit cube on screen.
struct CubeSceneView: UIViewRepresentable {
    let controller: CubeSceneController

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
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        if uiView.scene !== controller.scene {
            uiView.scene = controller.scene
        }
    }
}
