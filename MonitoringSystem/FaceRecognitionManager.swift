import Observation
import AVFoundation
import AppKit
import UserNotifications
import Vision

@MainActor
@Observable
class FaceRecognitionManager: NSObject {
    
    var cameraError: String? = nil
    var showCameraError: Bool = false
    
    static let cameraAccessDeniedNotification = Notification.Name("CameraAccessDenied")

    var isFaceDetected: Bool = true
    var lastFaceDetectedTime: Date = Date()

    private let absenceThreshold: TimeInterval = 3

    private var bounceRequestID: Int? = nil
    private(set) var sessionRecognizedTime: TimeInterval = 0
    private var faceDetectStart: Date? = nil
    private var isSessionActive: Bool = false

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

    private let captureSession = AVCaptureSession()
    private let videoOutput   = AVCaptureVideoDataOutput()

    override init() { super.init() }
    
    private final class TaskHolder {
        var task: Task<Void, Never>?
    }
        
    private let absenceTaskHolder = TaskHolder()
        
    deinit {
        absenceTaskHolder.task?.cancel()
    }

    func startCamera() async {
        guard await ensureCameraPermission() else { return }
        configureSession()
        startSession()
        startAbsenceCheck()
    }

    func stopCamera() {
        stopSession()
        absenceTaskHolder.task?.cancel()
        absenceTaskHolder.task = nil
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

            videoOutput.setSampleBufferDelegate(
                self,
                queue: DispatchQueue(label: "FaceRecognitionManager.cameraQueue")
            )
            if captureSession.canAddOutput(videoOutput) { captureSession.addOutput(videoOutput) }

            captureSession.sessionPreset = .medium
        } catch {
            cameraError = "カメラの初期化に失敗しました: \(error.localizedDescription)"
            showCameraError = true
            
            NotificationCenter.default.post(
                name: Notification.Name("CameraInitializationFailed"),
                object: nil,
                userInfo: ["error": error.localizedDescription]
            )
        }
    }

    private func startSession() { if !captureSession.isRunning { captureSession.startRunning() } }
    private func stopSession()  { if  captureSession.isRunning { captureSession.stopRunning() } }
    

    private func startAbsenceCheck() {
        absenceTaskHolder.task?.cancel()
        absenceTaskHolder.task = Task.detached { [weak self] in
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
    private func ensureCameraPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            let granted = await withCheckedContinuation { cont in
                AVCaptureDevice.requestAccess(for: .video) { cont.resume(returning: $0) }
            }
            if !granted {
                NotificationCenter.default.post(
                    name: Self.cameraAccessDeniedNotification, object: nil)
            }
            return granted
        default:
            NotificationCenter.default.post(
                name: Self.cameraAccessDeniedNotification, object: nil)
            return false
        }
    }
}


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
                    NotificationCenter.default.post(name: Notification.Name("FaceDetectionChanged"),
                                                    object: nil,
                                                    userInfo: ["isDetected": self.isFaceDetected])
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
                    NotificationCenter.default.post(name: Notification.Name("FaceDetectionChanged"),
                                                    object: nil,
                                                    userInfo: ["isDetected": self.isFaceDetected])
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
