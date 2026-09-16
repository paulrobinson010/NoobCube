import SceneKit
import SwiftUI
import UIKit

/// An arrow arcing from one square to the place it is about to end up.
///
/// The curled arrow around an axis says *which way to turn*. This one says
/// *where this square is going*, which is the question a child actually has:
/// they can see the sticker, and they want to know where it will be when the
/// turn is done. It bows outwards away from the cube so it reads as a journey
/// over the top rather than a line drawn on the surface.
extension CubeSceneController {

    func showJourney(from start: Int, to end: Int) {
        hideJourney()
        guard start != end,
              let from = stickerNodes[start]?.worldPosition,
              let to = stickerNodes[end]?.worldPosition else { return }

        let group = SCNNode()
        let colour = UIColor(Theme.done)

        // A curve that lifts away from the cube: the halfway point pushed out
        // from the middle, by more when the two squares are further apart.
        let straightLine = Self.distance(from, to)
        let lift = 1.35 + straightLine * 0.32
        let middle = Self.scaled(Self.midpoint(from, to), toLength: lift)

        let points = (0...18).map { step -> SCNVector3 in
            Self.onCurve(from: from, through: middle, to: to,
                         at: Float(step) / 18)
        }

        // The shaft, as a run of short rods. Simple, and it bends as far as we
        // like without any geometry of its own.
        for index in 0..<(points.count - 2) {
            group.addChildNode(Self.rod(from: points[index], to: points[index + 1],
                                        radius: 0.085, colour: colour))
        }

        // The head, pointing the way the last piece of the curve is going.
        let tip = points[points.count - 1]
        let approach = points[points.count - 2]
        let head = SCNNode(geometry: SCNCone(topRadius: 0, bottomRadius: 0.2, height: 0.42))
        head.geometry?.firstMaterial = Self.arrowMaterial(colour)
        head.position = Self.midpoint(approach, tip)
        head.look(at: tip, up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 1, 0))
        group.addChildNode(head)

        group.opacity = 0
        scene.rootNode.addChildNode(group)
        journeyNode = group

        let appear = SCNAction.fadeOpacity(to: 1, duration: 0.25)
        let breathe = SCNAction.sequence([
            .fadeOpacity(to: 0.62, duration: 0.7),
            .fadeOpacity(to: 1.0, duration: 0.7),
        ])
        group.runAction(.sequence([appear, .repeatForever(breathe)]))
    }

    func hideJourney() {
        journeyNode?.removeAllActions()
        journeyNode?.removeFromParentNode()
        journeyNode = nil
    }

    // MARK: - Bits and pieces

    private static func arrowMaterial(_ colour: UIColor) -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = colour
        material.emission.contents = UIColor(Theme.done.dimmed(to: 0.45))
        material.lightingModel = .physicallyBased
        material.roughness.contents = 0.4
        return material
    }

    /// One short rod between two points, which is all a curve needs to be.
    private static func rod(from: SCNVector3, to: SCNVector3,
                            radius: CGFloat, colour: UIColor) -> SCNNode {
        let length = distance(from, to)
        let cylinder = SCNCylinder(radius: radius, height: CGFloat(length))
        cylinder.radialSegmentCount = 8
        cylinder.firstMaterial = arrowMaterial(colour)

        let node = SCNNode(geometry: cylinder)
        node.position = midpoint(from, to)
        // A cylinder stands up its own y axis, so point that at the far end.
        node.look(at: to, up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 1, 0))
        return node
    }

    private static func onCurve(from: SCNVector3, through middle: SCNVector3,
                                to: SCNVector3, at t: Float) -> SCNVector3 {
        let inverse = 1 - t
        let a = inverse * inverse
        let b = 2 * inverse * t
        let c = t * t
        return SCNVector3(a * from.x + b * middle.x + c * to.x,
                          a * from.y + b * middle.y + c * to.y,
                          a * from.z + b * middle.z + c * to.z)
    }

    private static func midpoint(_ a: SCNVector3, _ b: SCNVector3) -> SCNVector3 {
        SCNVector3((a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2)
    }

    private static func distance(_ a: SCNVector3, _ b: SCNVector3) -> Float {
        let dx = a.x - b.x, dy = a.y - b.y, dz = a.z - b.z
        return (dx * dx + dy * dy + dz * dz).squareRoot()
    }

    /// The same direction from the middle of the cube, at a chosen distance.
    private static func scaled(_ point: SCNVector3, toLength length: Float) -> SCNVector3 {
        let size = (point.x * point.x + point.y * point.y + point.z * point.z).squareRoot()
        guard size > 0.0001 else { return SCNVector3(0, length, 0) }
        let factor = (size + length) / size
        return SCNVector3(point.x * factor, point.y * factor, point.z * factor)
    }
}
