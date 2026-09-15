import AVFoundation
import CoreVideo
import UIKit
import SwiftUI

/// Runs the camera and reads nine sticker colours out of each frame.
///
/// Only the middle square of the frame is used — the bit inside the on-screen
/// guide — and within it nine small patches are averaged. Averaging a patch
/// rather than reading one pixel keeps a glare spot or a sticker edge from
/// deciding a colour on its own.
@MainActor
final class CameraController: NSObject, ObservableObject {

    /// The nine colours currently under the guide, top-left first.
    @Published private(set) var liveSamples: [RGBSample] = []
    @Published private(set) var isRunning = false
    @Published private(set) var permissionDenied = false

    /// How still the reading has been, 0 to 1. Used to auto-capture.
    @Published private(set) var steadiness: Double = 0

    let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "noobcube.camera")
    private var recentReadings: [[RGBSample]] = []

    /// Fraction of the frame's short side the guide square covers. Static
    /// because the frame reader runs off the main actor.
    private static let guideFraction: Double = 0.62

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
            session.commitConfiguration()

            // Keep exposure and white balance steady, so the colours a child
            // sees do not drift while they turn the cube.
            try? device.lockForConfiguration()
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            device.unlockForConfiguration()
        }

        isRunning = true
        queue.async { [session] in
            if !session.isRunning { session.startRunning() }
        }
    }

    /// Average a small patch of the frame.
    private nonisolated func averageColour(in buffer: CVPixelBuffer,
                                           centreX: Int, centreY: Int, radius: Int,
                                           width: Int, height: Int,
                                           bytesPerRow: Int,
                                           base: UnsafeMutablePointer<UInt8>) -> RGBSample {
        var red = 0.0, green = 0.0, blue = 0.0, count = 0.0
        let minX = max(0, centreX - radius), maxX = min(width - 1, centreX + radius)
        let minY = max(0, centreY - radius), maxY = min(height - 1, centreY + radius)
        guard minX <= maxX, minY <= maxY else {
            return RGBSample(red: 0, green: 0, blue: 0)
        }
        // Step across the patch rather than reading every pixel: plenty of
        // samples, a fraction of the work per frame.
        let step = max(1, (maxX - minX) / 8)
        var y = minY
        while y <= maxY {
            let row = base.advanced(by: y * bytesPerRow)
            var x = minX
            while x <= maxX {
                let pixel = row.advanced(by: x * 4)
                blue += Double(pixel[0])
                green += Double(pixel[1])
                red += Double(pixel[2])
                count += 1
                x += step
            }
            y += step
        }
        guard count > 0 else { return RGBSample(red: 0, green: 0, blue: 0) }
        return RGBSample(red: red / count / 255,
                         green: green / count / 255,
                         blue: blue / count / 255)
    }

    fileprivate nonisolated func readStickers(from buffer: CVPixelBuffer) -> [RGBSample]? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        guard let rawBase = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let base = rawBase.assumingMemoryBound(to: UInt8.self)
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)

        let guideSide = Double(min(width, height)) * Self.guideFraction
        let cell = guideSide / 3
        let originX = Double(width) / 2 - guideSide / 2
        let originY = Double(height) / 2 - guideSide / 2
        let radius = Int(cell * 0.26)

        var samples: [RGBSample] = []
        samples.reserveCapacity(9)
        for row in 0..<3 {
            for column in 0..<3 {
                let x = Int(originX + cell * (Double(column) + 0.5))
                let y = Int(originY + cell * (Double(row) + 0.5))
                samples.append(averageColour(in: buffer,
                                             centreX: x, centreY: y, radius: radius,
                                             width: width, height: height,
                                             bytesPerRow: bytesPerRow, base: base))
            }
        }
        return samples
    }

    /// Track how much the reading is moving, so a face can be taken
    /// automatically once the cube is held still.
    private func updateSteadiness(with samples: [RGBSample]) {
        recentReadings.append(samples)
        if recentReadings.count > 8 { recentReadings.removeFirst() }
        guard recentReadings.count >= 4 else {
            steadiness = 0
            return
        }
        var drift = 0.0
        for index in 1..<recentReadings.count {
            for position in 0..<9 {
                let a = recentReadings[index][position]
                let b = recentReadings[index - 1][position]
                drift += abs(a.red - b.red) + abs(a.green - b.green) + abs(a.blue - b.blue)
            }
        }
        let normalised = drift / Double((recentReadings.count - 1) * 9 * 3)
        steadiness = max(0, min(1, 1 - normalised * 22))
    }

    func resetSteadiness() {
        recentReadings.removeAll()
        steadiness = 0
    }
}

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let samples = readStickers(from: buffer) else { return }
        Task { @MainActor in
            self.liveSamples = samples
            self.updateSteadiness(with: samples)
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
