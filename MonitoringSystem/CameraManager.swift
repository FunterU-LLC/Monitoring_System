import Observation
import Foundation
import AVFoundation
import Vision

@MainActor                 // ★ 追加
@Observable
class CameraManager: NSObject {

    // 外部バインド用
    var faceDetected: Bool = false

    // AVCapture 構成
    let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()

    override init() {
        super.init()
        configureSession()
    }

    // ────────── セッション構築 ──────────
    private func configureSession() {
        guard let device = AVCaptureDevice.default(for: .video) else {
            print("カメラデバイスが見つかりません。"); return
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if captureSession.canAddInput(input) { captureSession.addInput(input) }

            videoOutput.setSampleBufferDelegate(self,
                                                queue: .init(label: "cameraQueue"))
            if captureSession.canAddOutput(videoOutput) { captureSession.addOutput(videoOutput) }

            captureSession.sessionPreset = .medium
        } catch {
            print("カメラ入力の設定に失敗: \(error)")
        }
    }

    // ────────── セッション制御 ──────────
    func startSession() { if !captureSession.isRunning { captureSession.startRunning() } }
    func stopSession()  { if  captureSession.isRunning { captureSession.stopRunning() } }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {

    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {

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

