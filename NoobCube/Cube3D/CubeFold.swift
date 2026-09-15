import SceneKit
import UIKit

/// The unfolded net folding up into the cube.
///
/// Six flat faces are laid out exactly as ``CubeNetView`` draws them, then
/// hinged along the edges they share until they close into a cube. The folded
/// result is the same size and place as the cubelet cube, so when the fold
/// finishes the two are swapped and nothing appears to move.
///
///          [ U ]
///    [ L ] [ F ] [ R ] [ B ]
///          [ D ]
///
extension CubeSceneController {

    /// One face of the flat net: where it hangs, and how far it swings shut.
    private struct Hinge {
        let face: Face
        /// Where the hinge sits, in the flat net.
        let pivot: SCNVector3
        /// Which way the face lies from its hinge, before folding.
        let armLength: SCNVector3
        let axis: SCNVector3
        let angle: Float
    }

    private static let faceSpan: Float = 3.0
    private static let halfSpan: Float = 1.5

    private static var hinges: [Hinge] {
        let half = halfSpan
        return [
            // The front face does not move; everything folds back from it.
            Hinge(face: .F, pivot: SCNVector3(0, 0, half), armLength: SCNVector3(0, 0, 0),
                  axis: SCNVector3(1, 0, 0), angle: 0),
            Hinge(face: .U, pivot: SCNVector3(0, half, half), armLength: SCNVector3(0, half, 0),
                  axis: SCNVector3(1, 0, 0), angle: -.pi / 2),
            Hinge(face: .D, pivot: SCNVector3(0, -half, half), armLength: SCNVector3(0, -half, 0),
                  axis: SCNVector3(1, 0, 0), angle: .pi / 2),
            Hinge(face: .R, pivot: SCNVector3(half, 0, half), armLength: SCNVector3(half, 0, 0),
                  axis: SCNVector3(0, 1, 0), angle: .pi / 2),
            Hinge(face: .L, pivot: SCNVector3(-half, 0, half), armLength: SCNVector3(-half, 0, 0),
                  axis: SCNVector3(0, 1, 0), angle: -.pi / 2),
        ]
    }

    /// A hinge node paired with the turn that closes it.
    private struct Fold {
        let node: SCNNode
        let axis: SCNVector3
        let angle: Float
    }

    /// Lay the net out flat, ready to fold. Returns the folds to run.
    private func buildNet(colours: [CubeColour?]) -> [Fold] {
        netNodeChildrenRemoved()
        var folds: [Fold] = []

        for hinge in Self.hinges {
            let hingeNode = SCNNode()
            hingeNode.position = hinge.pivot
            let faceNode = makeNetFace(hinge.face, colours: colours)
            faceNode.position = hinge.armLength
            hingeNode.addChildNode(faceNode)
            netNode.addChildNode(hingeNode)
            if hinge.angle != 0 {
                folds.append(Fold(node: hingeNode, axis: hinge.axis, angle: hinge.angle))
            }

            // The back face hangs off the right-hand edge of the right face and
            // folds a second time, which is what the flat net does on paper.
            if hinge.face == .R {
                let backHinge = SCNNode()
                backHinge.position = SCNVector3(Self.halfSpan, 0, 0)
                let backFace = makeNetFace(.B, colours: colours)
                backFace.position = SCNVector3(Self.halfSpan, 0, 0)
                backHinge.addChildNode(backFace)
                faceNode.addChildNode(backHinge)
                folds.append(Fold(node: backHinge, axis: SCNVector3(0, 1, 0), angle: .pi / 2))
            }
        }
        return folds
    }

    private func netNodeChildrenRemoved() {
        for child in netNode.childNodes {
            child.removeFromParentNode()
        }
    }

    /// One face of the net: nine sticker tiles on a dark backing.
    private func makeNetFace(_ face: Face, colours: [CubeColour?]) -> SCNNode {
        let node = SCNNode()

        let backing = SCNBox(width: CGFloat(Self.faceSpan),
                             height: CGFloat(Self.faceSpan),
                             length: 0.08,
                             chamferRadius: 0.12)
        backing.firstMaterial?.diffuse.contents = UIColor(white: 0.07, alpha: 1)
        backing.firstMaterial?.lightingModel = .physicallyBased
        node.addChildNode(SCNNode(geometry: backing))

        for offset in 0..<9 {
            let row = offset / 3
            let column = offset % 3
            let index = face.rawValue * 9 + offset

            let side: CGFloat = 0.88
            let tile = SCNPlane(width: side, height: side)
            tile.cornerRadius = side * 0.16
            let material = SCNMaterial()
            let colour = index < colours.count ? colours[index] : nil
            material.diffuse.contents = colour.map(CubeSceneController.uiColor)
                ?? UIColor(white: 0.2, alpha: 1)
            material.lightingModel = .physicallyBased
            material.isDoubleSided = true
            tile.firstMaterial = material

            let tileNode = SCNNode(geometry: tile)
            // Local x runs with the face's columns and local y against its rows,
            // which is the same arrangement the flat net view draws.
            tileNode.position = SCNVector3(Float(column - 1) * 1.0,
                                           Float(1 - row) * 1.0,
                                           0.05)
            node.addChildNode(tileNode)
        }
        return node
    }

    /// Show the flat net, then fold it into the cube.
    ///
    /// The camera starts square-on to the net so it reads as a flat picture,
    /// and pulls round to the usual three-quarter view as the cube closes up.
    func foldNetIntoCube(colours: [CubeColour?],
                         duration: TimeInterval = 1.6,
                         completion: @MainActor @escaping () -> Void) {
        let folds = buildNet(colours: colours)
        setColours(colours)

        netNode.isHidden = false
        cubeNodeHidden(true)
        stopIdleSpin()

        let finalPosition = cameraRestingPosition
        let finalAngles = cameraRestingEulerAngles
        moveCameraSquareOnToNet()

        let pause = SCNAction.wait(duration: 0.45)
        for fold in folds {
            let turn = SCNAction.rotate(by: CGFloat(fold.angle),
                                        around: fold.axis,
                                        duration: duration * 0.7)
            turn.timingMode = .easeInEaseOut
            fold.node.runAction(.sequence([pause, turn]))
        }

        let move = SCNAction.move(to: finalPosition, duration: duration)
        let turn = SCNAction.rotateTo(x: CGFloat(finalAngles.x),
                                      y: CGFloat(finalAngles.y),
                                      z: CGFloat(finalAngles.z),
                                      duration: duration)
        move.timingMode = .easeInEaseOut
        turn.timingMode = .easeInEaseOut

        runOnCamera(.group([move, turn])) { [weak self] in
            guard let self else { return }
            self.netNode.isHidden = true
            self.netNodeChildrenRemoved()
            self.cubeNodeHidden(false)
            completion()
        }
    }
}
