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

/// The newest frame waiting to be taken up on the main actor.
///
/// Frames arrive sixty times a second on the capture queue, and taking one up
/// means five published changes and a redraw of the whole scanning screen.
/// Handing every frame over separately let them pile up without limit whenever
/// the main actor could not keep pace, and since the camera never pauses it
/// could not catch up either — the app simply stopped answering.
///
/// So at most one hand-over is ever in flight. Frames that arrive while it is
/// on its way replace the one waiting rather than joining a queue behind it,
/// which is also what you want: the newest frame is the only interesting one.
private final class PendingFrame: @unchecked Sendable {
    typealias Frame = (reading: CameraController.Reading, sawCube: Bool?, shapeCheckWorks: Bool)

    private let lock = NSLock()
    private var waiting: Frame?
    private var onItsWay = false

    /// Leaves the frame ready to be collected. True if the caller should be
    /// the one to go and collect it.
    func offer(_ frame: Frame) -> Bool {
        lock.lock(); defer { lock.unlock() }
        waiting = frame
        if onItsWay { return false }
        onItsWay = true
        return true
    }

    func collect() -> Frame? {
        lock.lock(); defer { lock.unlock() }
        onItsWay = false
        defer { waiting = nil }
        return waiting
    }
}

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

    /// Whether frames are actually arriving.
    @Published private(set) var isRunning = false
    /// Whether the camera is being woken up. Starting a capture session takes
    /// the best part of a second, and saying so beats a black rectangle.
    @Published private(set) var isStarting = false
    @Published private(set) var permissionDenied = false

    /// How still the reading has been, 0 to 1.
    @Published private(set) var steadiness: Double = 0

    /// How much of the steady window has been filled, 0 to 1.
    @Published private(set) var settling: Double = 0

    /// Whether the guide square is looking at a cube rather than the room.
    ///
    /// Decided by shape (see ``CubePresence``). While nothing cube-shaped has
    /// ever been seen — which is also what it looks like when the check does
    /// not work — this stays true, so it can never be the reason a scan fails.
    @Published private(set) var isCubeInFrame = true

    let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    /// Frames arrive here.
    private let queue = DispatchQueue(label: "noobcube.camera")
    /// Starting, stopping and configuring happen here, and nowhere else.
    ///
    /// Apart from the frame queue on purpose. That one is busy sixty times a
    /// second reading stickers and, every fourth frame, looking for a cube
    /// shape; a start or a stop sharing it would have to wait its turn behind
    /// all of that, which is the sort of coupling that turns a busy moment into
    /// a stuck camera.
    private let sessionQueue = DispatchQueue(label: "noobcube.camera.session")
    private var recentReadings: [[RGBSample]] = []
    private let previewGeometry = PreviewGeometry()
    private let pendingFrame = PendingFrame()

    /// Called on the main actor once each frame has been taken up.
    ///
    /// Whoever is scanning decides what to do with it. Driven by frames
    /// arriving rather than by the steadiness *changing*: the screen used to
    /// ask again only when that number moved, so the asking dried up exactly
    /// when the cube was being held stillest and the number stopped moving —
    /// and stopped altogether the moment the camera did.
    var onFrame: (() -> Void)?

    /// When the last frame arrived, so a session that has quietly died can be
    /// noticed and started again.
    private var lastFrameAt = Date.distantPast
    private var watchdog: Task<Void, Never>?
    /// The delayed lock of exposure and white balance, so coming back to the
    /// camera can cancel one that is still pending from last time.
    private var lockTask: Task<Void, Never>?

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
        lockTask?.cancel()
        lockTask = nil
        watchdog?.cancel()
        watchdog = nil
        isStarting = false
        sessionQueue.async { [weak self, session] in
            if session.isRunning { session.stopRunning() }
            let running = session.isRunning
            Task { @MainActor in self?.isRunning = running }
        }
    }

    /// Set the session up if it has never been set up, and start it.
    ///
    /// All of it on the capture queue. Building an input from the device and
    /// committing a session's configuration take their time, and doing that on
    /// the main thread means the screen the child is looking at is frozen for
    /// as long as it takes.
    ///
    /// Whether the session is running is the session's business, not a flag
    /// kept alongside it. Stopping used to say so straight away while the
    /// stopping itself waited its turn on the queue, so a start and a stop
    /// close together could leave the flag saying "running" over a session that
    /// had been stopped after it started — and every start after that would see
    /// the flag, decide there was nothing to do, and leave the screen black for
    /// good. Now the queue does both in order and reports back what is true.
    private func configureAndRun() {
        guard !isStarting else { return }
        permissionDenied = false
        isStarting = true

        let needsSetUp = session.inputs.isEmpty
        // Set before the session runs, so there are no frames in flight for
        // this to have to synchronise with.
        if needsSetUp { output.setSampleBufferDelegate(self, queue: queue) }

        sessionQueue.async { [weak self, session, output] in
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                       for: .video, position: .back) else {
                Task { @MainActor in
                    self?.permissionDenied = true
                    self?.isStarting = false
                }
                return
            }

            if needsSetUp {
                guard let input = try? AVCaptureDeviceInput(device: device),
                      session.canAddInput(input) else {
                    Task { @MainActor in
                        self?.permissionDenied = true
                        self?.isStarting = false
                    }
                    return
                }
                session.beginConfiguration()
                session.sessionPreset = .hd1280x720
                session.addInput(input)

                output.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                ]
                output.alwaysDiscardsLateVideoFrames = true
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
            }

            if !session.isRunning { session.startRunning() }
            let running = session.isRunning

            Task { @MainActor in
                guard let self else { return }
                self.isStarting = false
                self.isRunning = running
                if running {
                    self.lastFrameAt = Date()
                    self.judgeTheRoomAgain(device)
                    self.watchForAStalledSession()
                }
            }
        }
    }

    /// Notice a session that has stopped sending frames, and start it again.
    ///
    /// A capture session can stop delivering without saying so — the media
    /// server restarts, something else takes the camera, the app spends a
    /// moment in the background — and `isRunning` goes on reading true over a
    /// session that is not running. What that looks like is a black picture
    /// with the app still cheerfully asking for the next side, and no way out
    /// of it but to kill the app.
    ///
    /// Rather than trying to name every cause, this watches the one thing that
    /// matters: frames were arriving and now they are not. Whatever stopped
    /// them, starting the session again is the answer.
    private func watchForAStalledSession() {
        watchdog?.cancel()
        watchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                guard self.isRunning, !self.isStarting, !self.permissionDenied else { continue }
                guard Date().timeIntervalSince(self.lastFrameAt) > 3 else { continue }
                self.startAgainAfterAStall()
            }
        }
    }

    private func startAgainAfterAStall() {
        isRunning = false
        lastFrameAt = Date()
        sessionQueue.async { [weak self, session] in
            if session.isRunning { session.stopRunning() }
            Task { @MainActor in self?.start() }
        }
    }

    /// Let the camera judge the room, then hold it there.
    ///
    /// Auto white balance is the enemy here: it re-judges what counts as white
    /// every time the cube turns, so the same sticker reads differently from
    /// one side to the next. Locking it after a moment keeps all six sides
    /// measured under the same assumptions.
    ///
    /// Done every time the camera is come back to, not once ever. It used to
    /// run only when the session was first built, so a second scan was measured
    /// under a judgement made about the room as it was during the first one —
    /// and since the lock was never lifted, the picture could not adapt to a
    /// different room, a different lamp or a different distance. Waiting for a
    /// camera to come right when it has been told not to is a long wait.
    private func judgeTheRoomAgain(_ device: AVCaptureDevice) {
        lockTask?.cancel()

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

        lockTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, self != nil else { return }
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

    /// When a cube shape was last seen, and the shape check itself.
    private var lastSawCube = Date.distantPast
    private let presence = CubePresence()

    private nonisolated func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count % 2 == 1 { return sorted[middle] }
        return (sorted[middle - 1] + sorted[middle]) / 2
    }

    /// One frame's worth of reading: the nine squares, and whether what the
    /// camera is looking at is a cube at all.
    struct Reading: Sendable {
        var samples: [RGBSample]
        /// Whether the camera is looking at anything at all, as opposed to a
        /// pocket or a blown-out window.
        var isLit: Bool
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

        // Bright enough to be looking at something at all. Anything more
        // specific than that is done by shape, in CubePresence: the first
        // attempt tested for the black grid between stickers, which a
        // stickerless cube does not have — measured on a real one, the seams
        // came out 1.03 times the brightness of the squares, so the test threw
        // out exactly the cubes it was supposed to be reading.
        let light = median(samples.map { $0.hsv.value })
        let lit = light > 0.10 && light < 0.995

        return Reading(samples: samples, isLit: lit)
    }

    // MARK: - Settling

    /// Fold a new frame into the running window and re-derive the steady reading.
    private func accept(_ reading: Reading, sawCube: Bool?, shapeCheckWorks: Bool) {
        lastFrameAt = Date()
        defer { onFrame?() }
        if let sawCube, sawCube { lastSawCube = Date() }
        // An empty table is perfectly still, which is why stillness alone was
        // never enough to know there was anything to read. Until a cube shape
        // has ever been recognised the check has no opinion and is ignored.
        let recently = Date().timeIntervalSince(lastSawCube) < 0.8
        isCubeInFrame = reading.isLit && (!shapeCheckWorks || recently)

        guard isCubeInFrame else {
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
        lastSawCube = .distantPast
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

        let sawCube = presence.look(at: buffer)
        let settled = presence.hasAnOpinion

        guard pendingFrame.offer((reading, sawCube, settled)) else { return }
        Task { @MainActor in
            guard let frame = self.pendingFrame.collect() else { return }
            self.accept(frame.reading, sawCube: frame.sawCube,
                        shapeCheckWorks: frame.shapeCheckWorks)
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
