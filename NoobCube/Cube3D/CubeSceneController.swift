@preconcurrency import SceneKit
import UIKit
import SwiftUI

/// Builds and drives the 3D cube.
///
/// Two representations share one scene. The cube itself is 26 little cubelets,
/// which is what lets a single layer turn. The intro is six flat faces laid out
/// as the unfolded net, which fold up into exactly the same shape before the
/// cubelets take over, so the swap is invisible.
@MainActor
final class CubeSceneController {

    let scene = SCNScene()
    private let cubeNode = SCNNode()
    /// Holds the flat net during the folding intro.
    let netNode = SCNNode()
    private let cameraNode = SCNNode()

    /// Each cubelet with the lattice position it currently occupies.
    private var cubelets: [(node: SCNNode, position: Vec3)] = []

    /// Sticker plates by facelet index, so a step can light up the one square
    /// it is about and point an arrow at where that square is going.
    ///
    /// A facelet index is a *place* on the cube, not a sticker, so this has to
    /// be re-pointed every time a layer turns — see ``bake``.
    private(set) var stickerNodes: [Int: SCNNode] = [:]

    /// The curved arrow showing which way the next move goes, if one is showing.
    var arrowNode: SCNNode?

    /// The arrow arcing from a square to where it is about to end up, and the
    /// ring around the square it is going to.
    var journeyNode: SCNNode?
    var journeyRing: SCNNode?

    private static let cubeletSize: CGFloat = 1.0
    private static let gap: CGFloat = 0.06

    init() {
        scene.rootNode.addChildNode(cubeNode)
        scene.rootNode.addChildNode(netNode)
        setUpCamera()
        setUpLighting()
        buildCubelets()
        netNode.isHidden = true
    }

    // MARK: - Scene setup

    private func setUpCamera() {
        let camera = SCNCamera()
        camera.fieldOfView = 36
        camera.zNear = 0.1
        camera.zFar = 100
        camera.wantsHDR = false
        cameraNode.camera = camera
        // Looking down at the cube from the front-right-above, the angle that
        // shows three faces at once, so a child can see what is going on. The
        // angle itself is a design token, so the cube on the website and the
        // one in the app are posed identically and read as the same object.
        let pitch = -Theme.cubePitch
        let yaw = -Theme.cubeYaw
        let distance: Float = 11.1
        cameraNode.position = SCNVector3(distance * cos(pitch) * sin(yaw),
                                         distance * sin(pitch),
                                         distance * cos(pitch) * cos(yaw))
        cameraNode.look(at: SCNVector3(0, 0, 0))
        cameraRestingPosition = cameraNode.position
        cameraRestingEulerAngles = cameraNode.eulerAngles
        scene.rootNode.addChildNode(cameraNode)
    }

    private func setUpLighting() {
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 620
        ambient.light?.color = UIColor(white: 1, alpha: 1)
        scene.rootNode.addChildNode(ambient)

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 780
        key.position = SCNVector3(5, 9, 7)
        key.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(key)

        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .directional
        fill.light?.intensity = 300
        fill.position = SCNVector3(-6, 2, -4)
        fill.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(fill)
    }

    // MARK: - Building the cube

    private func buildCubelets() {
        let step = Float(Self.cubeletSize + Self.gap)
        for x in -1...1 {
            for y in -1...1 {
                for z in -1...1 {
                    let position = Vec3(x, y, z)
                    guard position.rank > 0 else { continue }   // skip the hidden core

                    let body = SCNBox(width: Self.cubeletSize,
                                      height: Self.cubeletSize,
                                      length: Self.cubeletSize,
                                      chamferRadius: Self.cubeletSize * 0.12)
                    body.firstMaterial = Self.plasticMaterial()

                    let node = SCNNode(geometry: body)
                    node.position = SCNVector3(Float(x) * step, Float(y) * step, Float(z) * step)

                    for face in Face.allCases where Vec3.dot(position, face.normal) == 1 {
                        let index = CubeGeometry.faceletIndex(position: position, normal: face.normal)
                        let sticker = makeSticker()
                        place(sticker, on: face)
                        node.addChildNode(sticker)
                        stickerNodes[index] = sticker
                    }

                    cubeNode.addChildNode(node)
                    cubelets.append((node, position))
                }
            }
        }
    }

    private static func plasticMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = UIColor(Theme.plastic)
        material.roughness.contents = 0.85
        material.metalness.contents = 0.0
        material.lightingModel = .physicallyBased
        return material
    }

    private func makeSticker() -> SCNNode {
        let side = Self.cubeletSize * Theme.stickerFraction
        let plate = SCNPlane(width: side, height: side)
        plate.cornerRadius = side * Theme.stickerRadius
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.white
        material.emission.contents = UIColor.black
        material.lightingModel = .physicallyBased
        material.roughness.contents = 0.45
        material.isDoubleSided = true
        plate.firstMaterial = material
        return SCNNode(geometry: plate)
    }

    /// Put a sticker plate just proud of one side of its cubelet.
    private func place(_ sticker: SCNNode, on face: Face) {
        let offset = Float(Self.cubeletSize / 2) + 0.005
        let normal = face.normal
        sticker.position = SCNVector3(Float(normal.x) * offset,
                                      Float(normal.y) * offset,
                                      Float(normal.z) * offset)
        switch face {
        case .F: break
        case .B: sticker.eulerAngles = SCNVector3(0, Float.pi, 0)
        case .R: sticker.eulerAngles = SCNVector3(0, Float.pi / 2, 0)
        case .L: sticker.eulerAngles = SCNVector3(0, -Float.pi / 2, 0)
        case .U: sticker.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
        case .D: sticker.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)
        }
    }

    // MARK: - Colours

    /// Paint the cube. Indices follow the facelet numbering, so a state from the
    /// solver can be drawn directly.
    func setColours(_ colours: [CubeColour?]) {
        for (index, node) in stickerNodes {
            guard let material = node.geometry?.firstMaterial else { continue }
            let colour = index < colours.count ? colours[index] : nil
            material.diffuse.contents = colour.map(Self.uiColor) ?? UIColor(white: 0.22, alpha: 1)
        }
    }

    static func uiColor(_ colour: CubeColour) -> UIColor {
        let (red, green, blue) = colour.rgb
        return UIColor(red: red, green: green, blue: blue, alpha: 1)
    }

    /// Make some stickers glow, to point at the pieces a step is about to move.
    func highlight(faceletIndices: Set<Int>) {
        for (index, node) in stickerNodes {
            guard let material = node.geometry?.firstMaterial else { continue }
            let glowing = faceletIndices.contains(index)
            material.emission.contents = glowing
                ? UIColor(white: 0.55, alpha: 1)
                : UIColor.black
        }
        pulse(faceletIndices)
    }

    /// Light up the one square this step is about, and nothing else.
    ///
    /// One square at a time on purpose. Lighting up a whole piece, or a piece
    /// and a gap in two colours, gives a child two things to look at and no
    /// idea which one is about to move; the arrow says where it is going.
    func highlight(square index: Int?) {
        let lookHere = UIColor(Theme.attention.dimmed(to: 0.55))
        for (facelet, node) in stickerNodes {
            guard let material = node.geometry?.firstMaterial else { continue }
            material.emission.contents = facelet == index ? lookHere : UIColor.black
        }
        pulse(index.map { [$0] } ?? [])
    }

    private func pulse(_ indices: Set<Int>) {
        for index in indices {
            guard let node = stickerNodes[index] else { continue }
            node.removeAction(forKey: "pulse")
            let grow = SCNAction.scale(to: 1.12, duration: 0.45)
            let shrink = SCNAction.scale(to: 1.0, duration: 0.45)
            grow.timingMode = .easeInEaseOut
            shrink.timingMode = .easeInEaseOut
            node.runAction(.repeatForever(.sequence([grow, shrink])), forKey: "pulse")
        }
        for (index, node) in stickerNodes where !indices.contains(index) {
            node.removeAction(forKey: "pulse")
            node.scale = SCNVector3(1, 1, 1)
        }
    }

    func clearHighlight() {
        highlight(square: nil)
        hideJourney()
    }

    /// Light up the three centres that fix how the cube should be held.
    ///
    /// Centres never move relative to each other, so naming three of them is
    /// all it takes to describe a grip.
    func highlightGrip() {
        highlight(faceletIndices: [Face.U.centreIndex, Face.D.centreIndex, Face.F.centreIndex])
    }

    // MARK: - Turning

    /// Animate one move, then put the cubelets back under the cube node with
    /// their new positions recorded.
    func animate(_ move: Move, duration: TimeInterval,
                 completion: @MainActor @escaping () -> Void) {
        let axis = move.turnAxis
        let turning = cubelets.indices.filter { move.moves(cubeletAt: cubelets[$0].position) }
        guard !turning.isEmpty else { return completion() }

        // The arrow has done its job once the layer is actually moving.
        dismissTurnArrow()

        // A pivot sitting at the origin with no transform of its own, so
        // re-parenting does not move anything.
        let pivot = SCNNode()
        cubeNode.addChildNode(pivot)
        for index in turning {
            pivot.addChildNode(cubelets[index].node)
        }

        // Clockwise seen from outside is a negative right-handed turn.
        let angle = -CGFloat.pi / 2 * CGFloat(move.amount.signedQuarterTurns)
        let rotation = SCNAction.rotate(by: angle,
                                        around: SCNVector3(Float(axis.x), Float(axis.y), Float(axis.z)),
                                        duration: duration)
        rotation.timingMode = .easeInEaseOut

        pivot.runAction(rotation) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.bake(pivot: pivot, turning: turning, move: move)
                completion()
            }
        }
    }

    /// Fold the pivot's rotation into each cubelet and hand them back, and
    /// re-point the sticker map at the plates that are now in each place.
    private func bake(pivot: SCNNode, turning: [Int], move: Move) {
        // The cube can be pulled apart and rebuilt while a turn is still
        // running — the little demo does it every time round the loop. A turn
        // that finishes after that is about cubelets that no longer exist, so
        // there is nothing left to fold in.
        guard pivot.parent != nil else { return }

        for node in pivot.childNodes {
            let combined = SCNMatrix4Mult(node.transform, pivot.transform)
            node.transform = combined
            cubeNode.addChildNode(node)
        }
        pivot.removeFromParentNode()

        for index in turning {
            let turns = move.amount.rawValue
            var position = cubelets[index].position
            for _ in 0..<turns {
                position = position.rotatedClockwise(about: move.turnAxis)
            }
            cubelets[index].position = position
        }

        // A facelet index names a place on the cube; the plate that was there
        // has just travelled somewhere else. Leaving the map alone meant that
        // after the first turn of a stage, lighting up "the square to watch"
        // lit whichever square happened to be standing in its old place, and
        // the arrow set off from there — so the arrow stopped matching the
        // move it was drawn for.
        stickerNodes = Self.moved(stickerNodes, by: move)
    }

    /// The sticker map after a move: the plate now in place `index` is the one
    /// that was in the place the move brings to `index`.
    ///
    /// The same permutation ``ScannedCube/applying(_:)`` uses to move colours,
    /// so the plates and the colours can never drift apart.
    static func moved(_ nodes: [Int: SCNNode], by move: Move) -> [Int: SCNNode] {
        guard let permutation = CubeGeometry.allPermutations[move] else { return nodes }
        var result: [Int: SCNNode] = [:]
        result.reserveCapacity(nodes.count)
        for index in 0..<54 {
            result[index] = nodes[permutation[index]]
        }
        return result
    }

    /// Put the cube back to a known state instantly, with no animation.
    func reset(to colours: [CubeColour?]) {
        hideTurnArrow()
        cubeNode.removeAllActions()
        for node in cubeNode.childNodes {
            node.removeAllActions()
            node.removeFromParentNode()
        }
        cubelets.removeAll()
        stickerNodes.removeAll()
        buildCubelets()
        setColours(colours)
        clearHighlight()
    }

    // MARK: - Camera and visibility, used by the folding intro

    /// Where the camera sits once the cube is assembled.
    private(set) var cameraRestingPosition = SCNVector3Zero
    private(set) var cameraRestingEulerAngles = SCNVector3Zero

    /// Which way the camera looks at the cube from, as a unit vector.
    var eye: SCNVector3 {
        let point = cameraRestingPosition
        let size = (point.x * point.x + point.y * point.y + point.z * point.z).squareRoot()
        guard size > 0.0001 else { return SCNVector3(0, 0, 1) }
        return SCNVector3(point.x / size, point.y / size, point.z / size)
    }

    /// True when this face is turned away from the camera, so anything drawn
    /// out beyond it is hidden by the plastic in front of it.
    ///
    /// Three of the six always are, and they are not rare: measured over 1,500
    /// solves, 6.3% of every move the method makes turns a face you cannot
    /// see — nearly all of them L, which "send it left", the way back to the
    /// fish and the edge swap all lean on. They arrive in clusters, so a child
    /// meets a run of moves with no arrow at all.
    func isFacingAway(_ face: Face) -> Bool {
        let normal = face.normal
        let towards = Float(normal.x) * eye.x + Float(normal.y) * eye.y + Float(normal.z) * eye.z
        return towards <= 0
    }

    /// True when this point sits round the back of the cube.
    func isRoundTheBack(_ point: SCNVector3) -> Bool {
        point.x * eye.x + point.y * eye.y + point.z * eye.z <= 0
    }

    /// Let something be seen through the plastic, faintly, the way a drawing
    /// shows a hidden edge. Being able to see it and knowing it is round the
    /// back are both needed: drawn at full strength it reads as floating in
    /// front of the cube, which is a different lie.
    static func showThroughTheCube(_ node: SCNNode, _ material: SCNMaterial) {
        material.readsFromDepthBuffer = false
        material.writesToDepthBuffer = false
        node.renderingOrder = 60
    }

    /// How strong an arrow is drawn: full in front, faint round the back.
    static func strength(behind: Bool) -> (low: CGFloat, high: CGFloat) {
        behind ? (0.26, 0.5) : (0.65, 1.0)
    }

    func cubeNodeHidden(_ hidden: Bool) {
        cubeNode.isHidden = hidden
    }

    /// Put the camera square on to the flat net, so it reads as a picture.
    func moveCameraSquareOnToNet() {
        cameraNode.removeAllActions()
        // The net is wider than it is tall and sits to the right of the origin,
        // because the back face hangs off the right-hand edge.
        cameraNode.position = SCNVector3(1.5, 0, 17.5)
        cameraNode.eulerAngles = SCNVector3Zero
    }

    func runOnCamera(_ action: SCNAction, completion: @MainActor @escaping () -> Void) {
        cameraNode.runAction(action) {
            Task { @MainActor in completion() }
        }
    }

    /// Slowly turn the whole cube, for the idle screens.
    func startIdleSpin() {
        cubeNode.removeAction(forKey: "idle")
        cubeNode.runAction(.repeatForever(.rotateBy(x: 0, y: CGFloat.pi * 2, z: 0, duration: 18)),
                           forKey: "idle")
    }

    func stopIdleSpin() {
        cubeNode.removeAction(forKey: "idle")
        cubeNode.eulerAngles = SCNVector3Zero
    }
}
