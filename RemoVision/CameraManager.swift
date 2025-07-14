import Observation
import Foundation
import AVFoundation
import Vision

@MainActor
@Observable
class CameraManager: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var cameraError: String? = nil
    var showCameraError: Bool = false
    var faceDetected: Bool = false

    let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private var isConfigured = false

    override init() {
        super.init()
    }

    private func configureSession() {
        guard let device = AVCaptureDevice.default(for: .video) else {
            cameraError = "カメラデバイスが見つかりません"
            showCameraError = true
            return
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if captureSession.canAddInput(input) { captureSession.addInput(input) }
            videoOutput.setSampleBufferDelegate(self, queue: .init(label: "cameraQueue"))
            if captureSession.canAddOutput(videoOutput) { captureSession.addOutput(videoOutput) }
            captureSession.sessionPreset = .medium
        } catch {
            cameraError = "カメラの設定に失敗しました: \(error.localizedDescription)"
            showCameraError = true
            NotificationCenter.default.post(
                name: Notification.Name("CameraConfigurationFailed"),
                object: nil,
                userInfo: ["error": error.localizedDescription]
            )
        }
    }

    func startSession() {
        if !isConfigured {
            configureSession()
            isConfigured = true
        }
        if !captureSession.isRunning { captureSession.startRunning() }
    }

    func stopSession() {
        if captureSession.isRunning { captureSession.stopRunning() }
    }

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let request = VNDetectFaceRectanglesRequest { [weak self] req, _ in
            guard let self else { return }
            let detected = (req.results as? [VNFaceObservation])?.isEmpty == false
            Task { @MainActor in self.faceDetected = detected }
        }
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        try? handler.perform([request])
    }
}
