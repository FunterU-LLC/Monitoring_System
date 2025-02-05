import Observation
import AVFoundation
import AppKit
import UserNotifications
import Vision

@MainActor
@Observable
class FaceRecognitionManager: NSObject {

    // ────────── 監視状態 ──────────
    var isFaceDetected: Bool = true
    var lastFaceDetectedTime: Date = Date()

    @MainActor(unsafe) private var absenceCheckTask: Task<Void, Never>?   // ← Timer→Task
    private let absenceThreshold: TimeInterval = 3

    private var bounceRequestID: Int? = nil
    private(set) var sessionRecognizedTime: TimeInterval = 0
    private var faceDetectStart: Date? = nil
    private var isSessionActive: Bool = false

    // ────────── セッション制御 ──────────
    func startRecognitionSession() {
        sessionRecognizedTime = 0
        faceDetectStart = nil
        isSessionActive = true
    }

    @discardableResult
    func endRecognitionSession() -> TimeInterval {
        if let start = faceDetectStart {
            let delta = Date().timeIntervalSince(start)
            sessionRecognizedTime += delta
            faceDetectStart = nil
        }
        isSessionActive = false
        return sessionRecognizedTime
    }

    // ────────── カメラ & Vision ──────────
    private let captureSession = AVCaptureSession()
    private let videoOutput   = AVCaptureVideoDataOutput()

    override init() { super.init() }
    deinit { absenceCheckTask?.cancel() }

    func startCamera() {
        configureSession()
        startSession()
        startAbsenceCheck()
    }

    func stopCamera() {
        stopSession()
        absenceCheckTask?.cancel()
        absenceCheckTask = nil
    }

    private func configureSession() {
        guard let device = AVCaptureDevice.default(for: .video) else {
            print("カメラデバイスが見つかりません。"); return
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if captureSession.canAddInput(input) { captureSession.addInput(input) }

            videoOutput.setSampleBufferDelegate(
                self,
                queue: DispatchQueue(label: "FaceRecognitionManager.cameraQueue")
            )
            if captureSession.canAddOutput(videoOutput) { captureSession.addOutput(videoOutput) }

            captureSession.sessionPreset = .medium
        } catch {
            print("カメラ入力の設定に失敗: \(error)")
        }
    }

    private func startSession() { if !captureSession.isRunning { captureSession.startRunning() } }
    private func stopSession()  { if  captureSession.isRunning { captureSession.stopRunning() } }

    // ────────── 不在チェック ──────────
    private func startAbsenceCheck() {
        absenceCheckTask?.cancel()
        absenceCheckTask = Task.detached { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if await !self.isFaceDetected {
                    let elapsed = await Date().timeIntervalSince(self.lastFaceDetectedTime)
                    if elapsed >= self.absenceThreshold {
                        await self.notifyUserCameraIssue()
                    }
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func notifyUserCameraIssue() async {
        if bounceRequestID == nil {
            bounceRequestID = NSApplication.shared.requestUserAttention(.criticalRequest)
        }
        let center = UNUserNotificationCenter.current()
        let granted = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        guard granted == true else { return }
        let content = UNMutableNotificationContent()
        content.title = "カメラがオフ、または長時間顔が認識されていません"
        content.body  = "在席ステータスが不在扱いになります。"
        let request = UNNotificationRequest(identifier: "CameraIssueNotification",
                                            content: content,
                                            trigger: nil)
        try? await center.add(request)
    }
}

// ────────── AVCaptureVideoDataOutputSampleBufferDelegate ──────────
extension FaceRecognitionManager: AVCaptureVideoDataOutputSampleBufferDelegate {

    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let request = VNDetectFaceRectanglesRequest { [weak self] req, _ in
            guard let self else { return }

            if let faces = req.results as? [VNFaceObservation], !faces.isEmpty {
                Task { @MainActor in
                    self.isFaceDetected = true
                    self.lastFaceDetectedTime = Date()
                    if self.isSessionActive, self.faceDetectStart == nil {
                        self.faceDetectStart = Date()
                    }
                    if let rid = self.bounceRequestID {
                        NSApplication.shared.cancelUserAttentionRequest(rid)
                        self.bounceRequestID = nil
                    }
                }
            } else {
                Task { @MainActor in
                    self.isFaceDetected = false
                    if self.isSessionActive, let start = self.faceDetectStart {
                        let delta = Date().timeIntervalSince(start)
                        self.sessionRecognizedTime += delta
                        self.faceDetectStart = nil
                    }
                }
            }
        }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        try? handler.perform([request])
    }
}

