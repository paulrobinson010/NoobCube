@preconcurrency import AVFoundation
import CoreVideo
import UIKit
import SwiftUI

/// Fraction of the frame's short side that the on-screen guide square covers.
///
/// At file scope rather than on the class: the frame reader runs off the main
/// actor, and a static property of a `@MainActor` type is isolated too.
private let guideFraction: Double = 0.62

/// How many frames are kept and reduced to one steady reading.
private let steadyWindow = 18

/// Where the preview is on screen, shared between the main actor and the
/// capture queue.
///
/// The frame reader has to know how big the preview is drawn to work out which
/// part of the camera buffer the guide square covers. That is written when the
/// view lays out and read on the capture queue, so it sits behind a lock rather
/// than actor isolation.
private final class PreviewGeometry: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = CGSize.zero

    var size: CGSize {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

/// Runs the camera and reads nine sticker colours out of each frame.
///
/// Reading a cube off a phone camera is noisy: the exposure hunts, hands move,
/// stickers glare, and the middle of a face often carries a printed logo. Three
/// things make the reading stable enough to trust:
///
///   * **Sample a ring, not a blob.** The middle of each square is skipped,
///     because that is where a logo sits, and so is the outer edge, because
///     that is where the black gap between stickers lands when the cube is not
///     perfectly square to the camera.
///   * **Take the median, not the mean.** A few stray points — a glare spot, a
///     fingertip, a gap — then cannot drag a colour anywhere.
///   * **Read over time, not once.** Every frame is kept for about half a
///     second and the median across them is what gets used, so a single bad
///     frame never decides a sticker.
@MainActor
final class CameraController: NSObject, ObservableObject {

    /// The nine colours in the newest frame, top-left first. Used for the live
    /// dots on screen, where a little flicker does not matter.
    @Published private(set) var liveSamples: [RGBSample] = []

    /// The nine colours settled over the recent frames. This is what a capture
    /// actually records.
    @Published private(set) var steadyReading: [RGBSample] = []

    @Published private(set) var isRunning = false
    @Published private(set) var permissionDenied = false

    /// How still the reading has been, 0 to 1.
    @Published private(set) var steadiness: Double = 0

    /// How much of the steady window has been filled, 0 to 1.
    @Published private(set) var settling: Double = 0

    /// Whether the guide square is looking at a cube rather than the room.
    @Published private(set) var isCubeInFrame = false

    let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "noobcube.camera")
    private var recentReadings: [[RGBSample]] = []
    private let previewGeometry = PreviewGeometry()

    /// Tell the reader how large the preview is drawn, so the square the child
    /// lines the cube up in is the square that actually gets sampled.
    func setPreviewSize(_ size: CGSize) {
        previewGeometry.size = size
    }

    // MARK: - Running the camera

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndRun()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    if granted { self?.configureAndRun() } else { self?.permissionDenied = true }
                }
            }
        default:
            permissionDenied = true
        }
    }

    func stop() {
        queue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
        isRunning = false
    }

    private func configureAndRun() {
        guard !isRunning else { return }
        permissionDenied = false

        if session.inputs.isEmpty {
            session.beginConfiguration()
            session.sessionPreset = .hd1280x720

            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                       for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else {
                session.commitConfiguration()
                permissionDenied = true
                return
            }
            session.addInput(input)

            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(output) {
                session.addOutput(output)
            }

            // Without this the buffers arrive the way the sensor sees the
            // world — on its side — while the preview layer quietly rotates
            // them for display. The sampling grid would then be at right
            // angles to the cube the child is looking at.
            if let connection = output.connection(with: .video) {
                if connection.isVideoRotationAngleSupported(90) {
                    connection.videoRotationAngle = 90          // portrait
                }
                connection.isVideoMirrored = false
            }
            session.commitConfiguration()

            configure(device)
        }

        isRunning = true
        queue.async { [session] in
            if !session.isRunning { session.startRunning() }
        }
    }

    /// Focus close, and stop the exposure and white balance hunting.
    ///
    /// Auto white balance is the enemy here: it re-judges what counts as white
    /// every time the cube turns, so the same sticker reads differently from
    /// one side to the next. Locking it after a moment keeps all six sides
    /// measured under the same assumptions.
    private func configure(_ device: AVCaptureDevice) {
        try? device.lockForConfiguration()
        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
        if device.isAutoFocusRangeRestrictionSupported {
            device.autoFocusRangeRestriction = .near
        }
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            device.whiteBalanceMode = .continuousAutoWhiteBalance
        }
        device.unlockForConfiguration()

        // Give it a second to settle on the scene, then hold it there.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard self != nil else { return }
            try? device.lockForConfiguration()
            if device.isWhiteBalanceModeSupported(.locked) {
                device.whiteBalanceMode = .locked
            }
            if device.isExposureModeSupported(.locked) {
                device.exposureMode = .locked
            }
            device.unlockForConfiguration()
        }
    }

    // MARK: - Reading a frame

    /// One sticker, as the median of a ring of points around its middle.
    private nonisolated func stickerColour(centreX: Double, centreY: Double, cell: Double,
                                           width: Int, height: Int, bytesPerRow: Int,
                                           base: UnsafeMutablePointer<UInt8>) -> RGBSample {
        // Radii as a fraction of the cell. Inside 0.2 is where a logo lives;
        // beyond 0.4 is where the gap between stickers starts.
        let rings: [(radius: Double, points: Int)] = [(0.22, 8), (0.29, 12), (0.36, 12)]

        var reds: [Double] = [], greens: [Double] = [], blues: [Double] = []
        reds.reserveCapacity(32)
        for ring in rings {
            let radius = cell * ring.radius
            for step in 0..<ring.points {
                let angle = 2 * Double.pi * Double(step) / Double(ring.points)
                let x = Int(centreX + radius * cos(angle))
                let y = Int(centreY + radius * sin(angle))
                guard x >= 0, x < width, y >= 0, y < height else { continue }
                let pixel = base.advanced(by: y * bytesPerRow + x * 4)
                blues.append(Double(pixel[0]))
                greens.append(Double(pixel[1]))
                reds.append(Double(pixel[2]))
            }
        }
        guard !reds.isEmpty else { return RGBSample(red: 0, green: 0, blue: 0) }
        return RGBSample(red: median(reds) / 255,
                         green: median(greens) / 255,
                         blue: median(blues) / 255)
    }

    private nonisolated func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count % 2 == 1 { return sorted[middle] }
        return (sorted[middle - 1] + sorted[middle]) / 2
    }

    /// One frame's worth of reading: the nine squares, and whether what the
    /// camera is looking at is a cube at all.
    struct Reading {
        var samples: [RGBSample]
        var looksLikeACube: Bool
    }

    /// The average brightness of a few pixels, for the gaps between stickers.
    private nonisolated func brightness(atX x: Double, y: Double, radius: Double,
                                        width: Int, height: Int, bytesPerRow: Int,
                                        base: UnsafeMutablePointer<UInt8>) -> Double? {
        var values: [Double] = []
        for step in 0..<6 {
            let angle = 2 * Double.pi * Double(step) / 6
            let px = Int(x + radius * cos(angle))
            let py = Int(y + radius * sin(angle))
            guard px >= 0, px < width, py >= 0, py < height else { continue }
            let pixel = base.advanced(by: py * bytesPerRow + px * 4)
            values.append(Double(max(pixel[0], max(pixel[1], pixel[2]))) / 255)
        }
        return values.isEmpty ? nil : median(values)
    }

    fileprivate nonisolated func readStickers(from buffer: CVPixelBuffer) -> Reading? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        guard let rawBase = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let base = rawBase.assumingMemoryBound(to: UInt8.self)
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)

        // The preview is drawn with aspect-fill, so it shows a centred crop of
        // the buffer. Undo that scale to find the guide square in buffer pixels.
        let preview = previewGeometry.size
        var guideSide = Double(min(width, height)) * guideFraction
        if preview.width > 1, preview.height > 1 {
            let fill = max(preview.width / Double(width), preview.height / Double(height))
            if fill > 0 {
                let onScreen = min(preview.width, preview.height) * guideFraction
                guideSide = onScreen / fill
            }
        }
        guideSide = min(guideSide, Double(min(width, height)))

        let cell = guideSide / 3
        let originX = Double(width) / 2 - guideSide / 2
        let originY = Double(height) / 2 - guideSide / 2

        var samples: [RGBSample] = []
        samples.reserveCapacity(9)
        for row in 0..<3 {
            for column in 0..<3 {
                samples.append(stickerColour(
                    centreX: originX + cell * (Double(column) + 0.5),
                    centreY: originY + cell * (Double(row) + 0.5),
                    cell: cell,
                    width: width, height: height,
                    bytesPerRow: bytesPerRow, base: base))
            }
        }

        // Is this a cube at all?
        //
        // A cube's stickers are separated by black plastic, and almost nothing
        // else the camera gets pointed at has a dark grid ruled across it. A
        // wall, a carpet or the ceiling is perfectly still, which is exactly
        // why the app used to settle on one and record a side of nothing.
        var gaps: [Double] = []
        for row in 0..<3 {
            for column in 0..<2 {
                if let value = brightness(atX: originX + cell * (Double(column) + 1),
                                          y: originY + cell * (Double(row) + 0.5),
                                          radius: cell * 0.06,
                                          width: width, height: height,
                                          bytesPerRow: bytesPerRow, base: base) {
                    gaps.append(value)
                }
            }
        }
        for row in 0..<2 {
            for column in 0..<3 {
                if let value = brightness(atX: originX + cell * (Double(column) + 0.5),
                                          y: originY + cell * (Double(row) + 1),
                                          radius: cell * 0.06,
                                          width: width, height: height,
                                          bytesPerRow: bytesPerRow, base: base) {
                    gaps.append(value)
                }
            }
        }

        let stickerLight = median(samples.map { $0.hsv.value })
        let gapLight = gaps.isEmpty ? stickerLight : median(gaps)
        // Bright enough to be looking at something, and ruled with lines
        // noticeably darker than the squares between them.
        let looksLikeACube = stickerLight > 0.12 && gapLight < stickerLight * 0.7

        return Reading(samples: samples, looksLikeACube: looksLikeACube)
    }

    // MARK: - Settling

    /// Fold a new frame into the running window and re-derive the steady reading.
    private func accept(_ reading: Reading) {
        // An empty table is perfectly still. Nothing settles until there is a
        // cube to settle on, so the app can no longer take a picture of a wall.
        isCubeInFrame = reading.looksLikeACube
        guard reading.looksLikeACube else {
            liveSamples = reading.samples
            resetSteadiness()
            return
        }

        let samples = reading.samples
        liveSamples = samples
        recentReadings.append(samples)
        if recentReadings.count > steadyWindow { recentReadings.removeFirst() }
        settling = min(1, Double(recentReadings.count) / Double(steadyWindow))

        // The steady reading: per sticker, the median of each channel across
        // every frame in the window.
        if recentReadings.count >= 3 {
            steadyReading = (0..<9).map { position in
                let window = recentReadings.compactMap { frame -> RGBSample? in
                    frame.indices.contains(position) ? frame[position] : nil
                }
                return RGBSample(red: median(window.map(\.red)),
                                 green: median(window.map(\.green)),
                                 blue: median(window.map(\.blue)))
            }
        }

        updateSteadiness()
    }

    /// How much the reading is moving, so a face can be taken automatically
    /// once the cube is held still and the window is full.
    private func updateSteadiness() {
        guard recentReadings.count >= 6 else {
            steadiness = 0
            return
        }
        // Compare only the newest few frames: an old, now-stale frame should
        // not keep the reading looking unsteady once the cube has settled.
        let recent = recentReadings.suffix(6)
        var drift = 0.0
        var previous: [RGBSample]?
        for frame in recent {
            if let previous {
                for position in 0..<min(9, frame.count, previous.count) {
                    drift += abs(frame[position].red - previous[position].red)
                        + abs(frame[position].green - previous[position].green)
                        + abs(frame[position].blue - previous[position].blue)
                }
            }
            previous = frame
        }
        let normalised = drift / Double((recent.count - 1) * 9 * 3)
        let stillness = max(0, min(1, 1 - normalised * 26))
        // Not steady until there is also enough history to take a median of.
        steadiness = min(stillness, settling)
    }

    func resetSteadiness() {
        recentReadings.removeAll()
        steadyReading = []
        steadiness = 0
        settling = 0
    }
}

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let reading = readStickers(from: buffer) else { return }
        Task { @MainActor in
            self.accept(reading)
        }
    }
}

/// The camera picture behind the scanning overlay.
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        if uiView.videoPreviewLayer.session !== session {
            uiView.videoPreviewLayer.session = session
        }
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}
