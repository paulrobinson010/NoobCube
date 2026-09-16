import SceneKit
import SwiftUI
import UIKit

/// A curved arrow wrapped around the axis a move turns about.
///
/// Words like "clockwise" mean very little to a five year old, so every move
/// also gets an arrow curling the way the layer is about to go. The arrow is
/// built as a flat outline and extruded, then stood up so its face points
/// straight out along the turning axis.
extension CubeSceneController {

    /// Show the arrow for a move. It fades in, then fades out as the layer turns.
    func showTurnArrow(for move: Move) {
        hideTurnArrow()

        let axis = move.turnAxis
        guard let face = Face.face(withNormal: axis) else { return }

        // Whole-cube turns get a bigger arrow further out, so it reads as
        // "turn everything" rather than "turn this layer".
        let isWholeCube = move.base.isRotation
        let innerRadius: CGFloat = isWholeCube ? 3.2 : 2.05
        let thickness: CGFloat = isWholeCube ? 0.34 : 0.28
        let standOff: Float = isWholeCube ? 0.6 : 1.85

        let clockwise = move.amount != .counterClockwise
        let sweep: CGFloat = move.amount == .half ? 4.4 : 3.1   // radians of arc

        let shape = SCNShape(path: Self.arrowOutline(innerRadius: innerRadius,
                                                     thickness: thickness,
                                                     sweep: sweep,
                                                     clockwise: clockwise),
                             extrusionDepth: 0.07)
        let material = SCNMaterial()
        // The colour the app uses everywhere for "this is the bit to look at".
        material.diffuse.contents = UIColor(Theme.attention)
        material.emission.contents = UIColor(Theme.attentionGlow)
        material.lightingModel = .constant
        material.isDoubleSided = true
        shape.firstMaterial = material

        let node = SCNNode(geometry: shape)

        // An L, D or B move stands its arrow out beyond a face the camera
        // cannot see, so the cube itself used to swallow it whole. Let it be
        // seen through the plastic instead, faintly.
        //
        // The arrow needs no mirroring to be read from the other side. It
        // depicts a rotation, and a rotation genuinely does look the other way
        // round from the far end of its axis — which is exactly what a child
        // holding the cube sees. Turning the drawing round to "correct" it
        // would be the thing that lied.
        let behind = isFacingAway(face)
        if behind { Self.showThroughTheCube(node, material) }
        // Stand the flat arrow up so it faces out along the turning axis, using
        // the same orientations the stickers use.
        node.eulerAngles = Self.orientation(facing: face)
        node.position = SCNVector3(Float(axis.x) * standOff,
                                   Float(axis.y) * standOff,
                                   Float(axis.z) * standOff)
        node.opacity = 0

        arrowNode = node
        scene.rootNode.addChildNode(node)

        let strength = Self.strength(behind: behind)
        let appear = SCNAction.fadeOpacity(to: strength.high, duration: 0.22)
        appear.timingMode = .easeOut
        let breathe = SCNAction.sequence([
            .fadeOpacity(to: strength.low, duration: 0.5),
            .fadeOpacity(to: strength.high, duration: 0.5),
        ])
        node.runAction(.sequence([appear, .repeatForever(breathe)]))
    }

    func hideTurnArrow() {
        arrowNode?.removeAllActions()
        arrowNode?.removeFromParentNode()
        arrowNode = nil
    }

    /// Fade the arrow out, for when the layer actually starts moving.
    func dismissTurnArrow(duration: TimeInterval = 0.2) {
        guard let node = arrowNode else { return }
        arrowNode = nil
        node.removeAllActions()
        node.runAction(.sequence([.fadeOut(duration: duration), .removeFromParentNode()]))
    }

    /// Euler angles that turn the XY plane to face outwards along `face`.
    static func orientation(facing face: Face) -> SCNVector3 {
        switch face {
        case .F: return SCNVector3(0, 0, 0)
        case .B: return SCNVector3(0, Float.pi, 0)
        case .R: return SCNVector3(0, Float.pi / 2, 0)
        case .L: return SCNVector3(0, -Float.pi / 2, 0)
        case .U: return SCNVector3(-Float.pi / 2, 0, 0)
        case .D: return SCNVector3(Float.pi / 2, 0, 0)
        }
    }

    /// The arrow as a single closed outline: a band along an arc, finished with
    /// a triangular head.
    ///
    /// Arcs are walked as short straight segments rather than drawn with
    /// `addArc`, so the winding does not depend on UIKit's flipped-coordinate
    /// conventions.
    private static func arrowOutline(innerRadius: CGFloat,
                                     thickness: CGFloat,
                                     sweep: CGFloat,
                                     clockwise: Bool) -> UIBezierPath {
        let inner = innerRadius
        let outer = innerRadius + thickness
        let middle = (inner + outer) / 2
        let headHalfWidth = thickness * 1.5
        let headSweep: CGFloat = 0.42

        // Looking from outside along the axis, angles grow anti-clockwise, so a
        // clockwise turn sweeps towards smaller angles.
        let direction: CGFloat = clockwise ? -1 : 1
        let start: CGFloat = clockwise ? sweep / 2 : -sweep / 2
        let tipAngle = start + direction * sweep
        let headBase = tipAngle - direction * headSweep

        func point(_ radius: CGFloat, _ angle: CGFloat) -> CGPoint {
            CGPoint(x: radius * cos(angle), y: radius * sin(angle))
        }

        func walk(_ path: UIBezierPath, radius: CGFloat, from: CGFloat, to: CGFloat) {
            let steps = max(8, Int(abs(to - from) / 0.05))
            for step in 1...steps {
                let angle = from + (to - from) * CGFloat(step) / CGFloat(steps)
                path.addLine(to: point(radius, angle))
            }
        }

        let path = UIBezierPath()
        path.move(to: point(outer, start))
        walk(path, radius: outer, from: start, to: headBase)
        path.addLine(to: point(middle + headHalfWidth, headBase))
        path.addLine(to: point(middle, tipAngle))
        path.addLine(to: point(middle - headHalfWidth, headBase))
        path.addLine(to: point(inner, headBase))
        walk(path, radius: inner, from: headBase, to: start)
        path.close()
        path.flatness = 0.02
        return path
    }
}
