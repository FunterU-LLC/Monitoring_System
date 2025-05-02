//CameraManager.swift
import Observation
import Foundation
import AVFoundation
import Vision

@MainActor
@Observable
class CameraManager: NSObject {
    var faceDetected: Bool = false

    let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()

    override init() {
        super.init()
        configureSession()
    }

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

    func startSession() { if !captureSession.isRunning { captureSession.startRunning() } }
    func stopSession()  { if  captureSession.isRunning { captureSession.stopRunning() } }
}

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

