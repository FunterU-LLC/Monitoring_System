import Combine          // AnyCancellable を使うために残す
import Observation
import AppKit
import SwiftUI

struct AggregatedUsage: Identifiable {
    let id = UUID()
    let appName: String
    let totalTime: Double
}

@Observable
class AppUsageManager: NSObject {
    // ────────── 公開プロパティ ──────────
    var logs: [AppUsageLog] = []
    var aggregatedResults: [AggregatedUsage] = []

    // ────────── 内部状態 ──────────
    private var currentApp: String      = ""
    private var currentStartTime: Date  = Date()
    private var isTracking:    Bool     = false

    private var recognizedAppUsage: [String: TimeInterval] = [:]
    private var currentRecognizedApp: String? = nil
    private var recognizedAppStart:    Date?  = nil

    private var faceDetected: Bool = false
    private var faceDetectCancellable: AnyCancellable?

    // ────────── 初期化 / 解放 ──────────
    override init() { super.init() }
    deinit { stopWork() }

    // ────────── 作業開始 ──────────
    func startWork(faceRecognitionManager: FaceRecognitionManager) {
        guard !isTracking else { return }
        isTracking = true

        // 前面アプリ監視
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        // 顔検出イベント購読
        faceDetectCancellable = NotificationCenter.default
            .publisher(for: Notification.Name("FaceDetectionChanged"))
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self = self,
                      let detected = notification.userInfo?["isDetected"] as? Bool else { return }
                self.faceDetected = detected
                detected ? self.startRecognizedApp()
                         : self.stopRecognizedApp()
            }

        // 現在の最前面アプリを即時取得
        if let frontApp = NSWorkspace.shared.frontmostApplication {
            let bundleId = frontApp.bundleIdentifier ?? "UnknownBundle"
            let appName  = frontApp.localizedName ?? "UnknownApp"
            print("最前面アプリ(開始時): \(appName), バンドルID: \(bundleId)")

            if !currentApp.isEmpty,
               let idx = logs.lastIndex(where: { $0.appName == currentApp && $0.endTime == nil }) {
                logs[idx].endTime = Date()
            }

            currentApp      = bundleId
            currentStartTime = Date()

            logs.append(AppUsageLog(bundleId: bundleId,
                                    appName:  appName,
                                    startTime: currentStartTime,
                                    endTime:   nil))

            stopRecognizedApp()
            if faceDetected { startRecognizedApp() }
        }
    }

    // ────────── 作業終了 ──────────
    func stopWork() {
        guard isTracking else { return }

        NSWorkspace.shared.notificationCenter.removeObserver(
            self,
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        if !currentApp.isEmpty,
           let idx = logs.lastIndex(where: { $0.appName == currentApp && $0.endTime == nil }) {
            logs[idx].endTime = Date()
        }

        faceDetectCancellable?.cancel()
        faceDetectCancellable = nil
        faceDetected = false

        stopRecognizedApp()
        isTracking     = false
        currentApp     = ""
        currentStartTime = Date()
    }

    // ────────── アプリ切替通知 ──────────
    @objc private func appDidActivate(_ notification: Notification) {
        guard isTracking,
              let runningApp = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }

        let bundleId = runningApp.bundleIdentifier ?? "UnknownBundle"
        let appName  = runningApp.localizedName ?? "UnknownApp"

        guard bundleId != currentApp else { return }

        print("最前面アプリ: \(appName), バンドルID: \(bundleId)")

        if !currentApp.isEmpty,
           let idx = logs.lastIndex(where: { $0.appName == currentApp && $0.endTime == nil }) {
            logs[idx].endTime = Date()
        }

        currentApp      = bundleId
        currentStartTime = Date()

        logs.append(AppUsageLog(bundleId: bundleId,
                                appName:  appName,
                                startTime: currentStartTime,
                                endTime:   nil))

        stopRecognizedApp()
        if faceDetected { startRecognizedApp() }
    }

    // ────────── 顔検出ありアプリ判定 ──────────
    private func startRecognizedApp() {
        guard currentRecognizedApp == nil, !currentApp.isEmpty else { return }
        currentRecognizedApp = currentApp
        recognizedAppStart   = Date()
    }

    private func stopRecognizedApp() {
        guard let app = currentRecognizedApp,
              let start = recognizedAppStart else { return }
        let delta = Date().timeIntervalSince(start)
        recognizedAppUsage[app, default: 0] += delta

        currentRecognizedApp = nil
        recognizedAppStart   = nil
    }

    // ────────── 集計 / デバッグ ──────────
    func calculateAggregatedUsage() {
        for i in logs.indices where logs[i].endTime == nil {
            logs[i].endTime = Date()
        }

        var usageDict = [String: TimeInterval]()
        for log in logs {
            let duration = (log.endTime ?? log.startTime)
                           .timeIntervalSince(log.startTime)
            usageDict[log.appName, default: 0] += duration
        }

        aggregatedResults = usageDict.map { AggregatedUsage(appName: $0.key, totalTime: $0.value) }
        logs.removeAll()
    }

    func printRecognizedAppUsage() {
        stopRecognizedApp()
        print("===== 顔認識ありアプリ使用時間 =====")
        for (app, time) in recognizedAppUsage {
            print("\(app): \(time) 秒")
        }
        recognizedAppUsage.removeAll()
    }

    // ────────── 外部 API ──────────
    func currentRecognizedAppUsageArray() -> [AppUsage] {
        stopRecognizedApp()
        let arr = recognizedAppUsage.map { AppUsage(name: $0.key, seconds: $0.value) }
        recognizedAppUsage.removeAll()
        return arr
    }

    func snapshotRecognizedUsage() -> [String: TimeInterval] {
        stopRecognizedApp(); return recognizedAppUsage
    }
    func clearRecognizedUsage() { recognizedAppUsage.removeAll() }
}
