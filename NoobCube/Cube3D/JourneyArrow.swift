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

        // A curve that clears the cube and no more. Pushing the halfway point
        // out by an amount that grew with the distance threw a great loop out
        // into space for a short hop, which read as a stray green tube rather
        // than as "this square goes there".
        let middle = Self.justOutside(Self.midpoint(from, to))

        let points = (0...16).map { step -> SCNVector3 in
            Self.onCurve(from: from, through: middle, to: to,
                         at: Float(step) / 16)
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
        let head = SCNNode(geometry: SCNCone(topRadius: 0, bottomRadius: 0.19, height: 0.4))
        head.geometry?.firstMaterial = Self.arrowMaterial(colour)
        head.position = Self.midpoint(approach, tip)
        head.look(at: tip, up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 1, 0))
        group.addChildNode(head)

        // A ring around the square it is going to, so where the arrow ends is
        // never in doubt.
        if let landing = stickerNodes[end] {
            let ring = Self.ring(colour: colour, radius: 0.28)
            landing.addChildNode(ring)
            journeyRing = ring
        }

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
        journeyRing?.removeFromParentNode()
        journeyRing = nil
    }

    /// A ring that sits on a sticker, following it wherever the sticker goes.
    static func ring(colour: UIColor, radius: CGFloat) -> SCNNode {
        let torus = SCNTorus(ringRadius: radius, pipeRadius: 0.042)
        torus.ringSegmentCount = 24
        torus.pipeSegmentCount = 6
        let material = SCNMaterial()
        material.diffuse.contents = colour
        material.emission.contents = colour
        material.lightingModel = .constant
        torus.firstMaterial = material

        let node = SCNNode(geometry: torus)
        // A torus lies flat in x-z; a sticker faces along its own z, so stand
        // the ring up to match, just proud of the plastic.
        node.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)
        node.position = SCNVector3(0, 0, 0.02)
        return node
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

    /// The same direction from the middle of the cube, far enough out to clear
    /// the corners and not a step further.
    private static func justOutside(_ point: SCNVector3) -> SCNVector3 {
        let size = (point.x * point.x + point.y * point.y + point.z * point.z).squareRoot()
        let clearance: Float = 2.75
        guard size > 0.0001 else { return SCNVector3(0, clearance, 0) }
        let factor = max(clearance, size + 0.3) / size
        return SCNVector3(point.x * factor, point.y * factor, point.z * factor)
    }
}
