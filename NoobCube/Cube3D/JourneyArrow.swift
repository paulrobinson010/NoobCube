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

        // Lift both ends off the plastic so the tube does not bury itself in
        // the square it starts and finishes on.
        let start3D = Self.pushedOut(from, by: 0.16)
        let end3D = Self.pushedOut(to, by: 0.16)

        let points = (0...22).map { step in
            Self.onArc(from: start3D, to: end3D, at: Float(step) / 22)
        }

        // The shaft, as a run of short rods. Simple, and it bends as far as we
        // like without any geometry of its own.
        for index in 0..<(points.count - 2) {
            group.addChildNode(Self.rod(from: points[index], to: points[index + 1],
                                        radius: 0.115, colour: colour))
        }

        // The head, pointing the way the last piece of the curve is going.
        let tip = points[points.count - 1]
        let approach = points[points.count - 2]
        let head = SCNNode(geometry: SCNCone(topRadius: 0, bottomRadius: 0.26, height: 0.55))
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

    /// How far out the arc rides. The cube's corners are 2.2 from the middle,
    /// so this leaves a clear gap over the top of everything.
    private static let clearance: Float = 3.3

    /// A point along an arc that sweeps *around* the cube.
    ///
    /// The first version bent a single curve between the two squares, which
    /// works for a short hop and fails badly for a long one: a square going
    /// from the top of the cube to the bottom had its arrow drawn straight
    /// through the middle of it. Swinging the direction round from one square
    /// to the other, and riding out and back in as it goes, gives an arc that
    /// clears the cube whichever two squares it joins.
    private static func onArc(from: SCNVector3, to: SCNVector3, at t: Float) -> SCNVector3 {
        let fromLength = length(from), toLength = length(to)
        let a = normalised(from), b = normalised(to)
        let angle = acos(max(-1, min(1, dot(a, b))))

        let direction: SCNVector3
        if angle < 0.001 {
            direction = a
        } else if abs(angle - .pi) < 0.001 {
            // Opposite sides of the cube: any plane between them will do, so
            // take one that is not edge-on.
            let axis: SCNVector3 = abs(a.y) < 0.9 ? SCNVector3(0, 1, 0) : SCNVector3(1, 0, 0)
            let across = normalised(cross(a, axis))
            direction = normalised(add(scaled(a, cos(.pi * t)), scaled(across, sin(.pi * t))))
        } else {
            let sweep = sin(angle)
            direction = normalised(add(scaled(a, sin((1 - t) * angle) / sweep),
                                       scaled(b, sin(t * angle) / sweep)))
        }

        let rise = max(0, clearance - (fromLength + toLength) / 2)
        let radius = fromLength + (toLength - fromLength) * t + rise * sin(.pi * t)
        return scaled(direction, radius)
    }

    // MARK: - Vector odds and ends

    private static func length(_ point: SCNVector3) -> Float {
        dot(point, point).squareRoot()
    }

    private static func dot(_ a: SCNVector3, _ b: SCNVector3) -> Float {
        a.x * b.x + a.y * b.y + a.z * b.z
    }

    private static func cross(_ a: SCNVector3, _ b: SCNVector3) -> SCNVector3 {
        SCNVector3(a.y * b.z - a.z * b.y,
                   a.z * b.x - a.x * b.z,
                   a.x * b.y - a.y * b.x)
    }

    private static func add(_ a: SCNVector3, _ b: SCNVector3) -> SCNVector3 {
        SCNVector3(a.x + b.x, a.y + b.y, a.z + b.z)
    }

    private static func scaled(_ point: SCNVector3, _ factor: Float) -> SCNVector3 {
        SCNVector3(point.x * factor, point.y * factor, point.z * factor)
    }

    private static func normalised(_ point: SCNVector3) -> SCNVector3 {
        let size = length(point)
        return size < 0.0001 ? point : scaled(point, 1 / size)
    }

    private static func midpoint(_ a: SCNVector3, _ b: SCNVector3) -> SCNVector3 {
        scaled(add(a, b), 0.5)
    }

    private static func distance(_ a: SCNVector3, _ b: SCNVector3) -> Float {
        length(SCNVector3(a.x - b.x, a.y - b.y, a.z - b.z))
    }

    /// The same point, moved out away from the middle of the cube.
    private static func pushedOut(_ point: SCNVector3, by amount: Float) -> SCNVector3 {
        let size = length(point)
        guard size > 0.0001 else { return point }
        return scaled(point, (size + amount) / size)
    }
}
