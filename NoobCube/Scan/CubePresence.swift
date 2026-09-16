import CoreVideo
import Foundation
import Vision

/// Whether the camera is looking at something cube-shaped.
///
/// This has to be decided by shape, not by colour. Colour cannot tell a white
/// cube face from a white wall, and the first attempt — looking for the black
/// grid between the stickers — was worse than useless: measured on a real
/// stickerless cube the seams came out slightly *brighter* than the squares,
/// so the test threw out exactly the cubes it was meant to be reading.
///
/// Vision looks for a roughly square edge near the middle of the frame, which
/// is what a cube face held up to the camera is. It does not care whether the
/// squares are stickers or moulded plastic.
///
/// Nothing here is ever allowed to stop a scan. If no rectangle is ever found —
/// a cube the same colour as the table behind it, a device where this does not
/// work — `hasAnOpinion` stays false and the app carries on as if the check did
/// not exist. A check that can refuse a real cube must not be load-bearing.
final class CubePresence: @unchecked Sendable {

    private let request: VNDetectRectanglesRequest = {
        let request = VNDetectRectanglesRequest()
        // A cube face seen at a slight angle is still close to square.
        request.minimumAspectRatio = 0.5
        request.maximumAspectRatio = 1.0
        request.quadratureTolerance = 40
        // It should be a decent part of the picture: the child is asked to
        // fill the guide square with it.
        request.minimumSize = 0.22
        request.minimumConfidence = 0.4
        request.maximumObservations = 6
        return request
    }()

    /// True once a rectangle has been seen at least once, so we know the check
    /// works here at all.
    private(set) var hasAnOpinion = false

    private var frames = 0

    /// Look at one frame in every few.
    ///
    /// Looking for a shape costs more than reading nine points, and a cube does
    /// not appear and vanish between frames. Returns nil on the frames it skips.
    func look(at buffer: CVPixelBuffer) -> Bool? {
        frames += 1
        guard frames % 4 == 0 else { return nil }
        return lookedLikeACube(in: buffer)
    }

    /// Look at one frame. Returns whether a cube-ish shape is in the middle.
    private func lookedLikeACube(in buffer: CVPixelBuffer) -> Bool {
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return false
        }
        guard let found = request.results as? [VNRectangleObservation] else { return false }

        // Near the middle, because that is where the guide square is and where
        // the child has been asked to hold it.
        let middle = found.contains { observation in
            let box = observation.boundingBox
            let centreX = box.midX, centreY = box.midY
            return centreX > 0.15 && centreX < 0.85 && centreY > 0.15 && centreY < 0.85
        }
        if middle { hasAnOpinion = true }
        return middle
    }
}
