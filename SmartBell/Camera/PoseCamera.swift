//
//  PoseCamera.swift
//  SmartBell — Camera
//
//  Camera capture + body-pose detection, and the two SwiftUI pieces that display it:
//    • PoseCamera      – AVCaptureSession → VNDetectHumanBodyPoseRequest → PoseFrame
//    • CameraPreview   – the live video layer
//    • SkeletonOverlay – draws the detected joints and bones on top of the preview
//  AppModel sets `onFrame` and sends each frame to CameraLab / the active workout.
//
//  Threads: session setup on `sessionQueue`, frame processing on `videoQueue`,
//  published results on the main thread.
//

import AVFoundation
import Vision
import SwiftUI
import UIKit

/// Phone camera + Apple Vision body-pose detection.
///
/// Frames are captured in portrait (rotated by the capture connection), so Vision runs with
/// orientation `.up` and joint coordinates line up with what the preview shows. The front camera
/// is mirrored in both the frames and the preview, so the overlay matches what you see.
/// Vision runs on a background queue; results are published on the main thread.
final class PoseCamera: NSObject, ObservableObject {
    enum Status: Equatable { case idle, starting, running, denied, unavailable }

    @Published private(set) var status = Status.idle
    @Published private(set) var frame: PoseFrame?
    @Published private(set) var fps = 0.0
    @Published private(set) var usingFront = false

    /// Called on the main thread for every processed frame (nil = nobody detected).
    var onFrame: ((PoseFrame?) -> Void)?

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "smartbell.camera.session")
    private let videoQueue = DispatchQueue(label: "smartbell.camera.video", qos: .userInitiated)
    private let output = AVCaptureVideoDataOutput()
    private var outputAdded = false
    private var users = 0                      // reference count of views that need the camera
    private var lastFrameTime: TimeInterval?   // for the fps estimate

    /// Views call start() on appear and stop() on disappear; the camera runs while anyone needs it.
    func start() {
        users += 1
        guard users == 1 else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndRun(front: usingFront)
        case .notDetermined:
            status = .starting
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted { self.configureAndRun(front: self.usingFront) } else { self.status = .denied }
                }
            }
        default:
            status = .denied
        }
    }

    func stop() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
        status = .idle
        frame = nil
    }

    /// Switch between front and back cameras.
    func flip() {
        usingFront.toggle()
        if users > 0 { configureAndRun(front: usingFront) }
    }

    private func configureAndRun(front: Bool) {
        status = .starting
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let ok = self.configure(front: front)
            if ok && !self.session.isRunning { self.session.startRunning() }
            DispatchQueue.main.async { self.status = ok ? .running : .unavailable }
        }
    }

    /// Runs on sessionQueue.
    private func configure(front: Bool) -> Bool {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
        for input in session.inputs { session.removeInput(input) }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: front ? .front : .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return false }
        session.addInput(input)

        if !outputAdded {
            output.alwaysDiscardsLateVideoFrames = true  // never queue up stale frames
            output.setSampleBufferDelegate(self, queue: videoQueue)
            guard session.canAddOutput(output) else { return false }
            session.addOutput(output)
            outputAdded = true
        }
        if let c = output.connection(with: .video) {
            if c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 } // portrait buffers
            if c.isVideoMirroringSupported {
                c.automaticallyAdjustsVideoMirroring = false
                c.isVideoMirrored = front
            }
        }
        return true
    }
}

extension PoseCamera: AVCaptureVideoDataOutputSampleBufferDelegate {
    /// Runs on videoQueue for every frame: detect the most confident person, convert
    /// their joints to PoseFrame, then publish on the main thread.
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        let size = CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))

        let request = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up, options: [:])
        var result: PoseFrame?
        if (try? handler.perform([request])) != nil,
           let obs = request.results?.max(by: { $0.confidence < $1.confidence }) {
            var pts: [Joint: CGPoint] = [:]
            var conf: [Joint: Float] = [:]
            for j in Joint.allCases {
                guard let p = try? obs.recognizedPoint(j.visionName) else { continue }
                // Vision: origin bottom-left. Convert to top-left like the screen.
                pts[j] = CGPoint(x: p.location.x, y: 1 - p.location.y)
                conf[j] = p.confidence
            }
            if !pts.isEmpty { result = PoseFrame(points: pts, confidence: conf, imageSize: size, time: time) }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Smoothed frames per second for display.
            if let last = self.lastFrameTime, time > last {
                self.fps = self.fps * 0.9 + (1 / (time - last)) * 0.1
            }
            self.lastFrameTime = time
            self.frame = result
            self.onFrame?(result)
        }
    }
}

/// Live camera preview. Uses aspect-fit so the skeleton overlay can be mapped exactly.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        override func layoutSubviews() {
            super.layoutSubviews()
            if let c = previewLayer.connection, c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
        }
    }

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspect
        v.backgroundColor = .black
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        if let c = uiView.previewLayer.connection, c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
    }
}

/// Skeleton drawn over the preview. Maps normalised image points into the aspect-fit rectangle.
struct SkeletonOverlay: View {
    var frame: PoseFrame?
    var highlight: Set<Joint> = []

    var body: some View {
        Canvas { ctx, size in
            guard let f = frame, f.imageSize.width > 0, f.imageSize.height > 0 else { return }
            // Same aspect-fit math as the preview layer: scale, then centre (letterbox offsets ox, oy).
            let s = min(size.width / f.imageSize.width, size.height / f.imageSize.height)
            let w = f.imageSize.width * s, h = f.imageSize.height * s
            let ox = (size.width - w) / 2, oy = (size.height - h) / 2
            func map(_ p: CGPoint) -> CGPoint { CGPoint(x: ox + p.x * w, y: oy + p.y * h) }

            for (a, b) in Joint.bones {
                guard let pa = f.point(a), let pb = f.point(b) else { continue }
                var path = Path()
                path.move(to: map(pa))
                path.addLine(to: map(pb))
                // Bones used by the current exercise's angle are drawn thicker in yellow.
                let hot = highlight.contains(a) && highlight.contains(b)
                ctx.stroke(path, with: .color(hot ? .yellow : .green), style: StrokeStyle(lineWidth: hot ? 5 : 3, lineCap: .round))
            }
            for j in Joint.allCases {
                guard let p = f.point(j) else { continue }
                let q = map(p)
                ctx.fill(Path(ellipseIn: CGRect(x: q.x - 5, y: q.y - 5, width: 10, height: 10)), with: .color(.white))
            }
        }
        .allowsHitTesting(false)
    }
}
