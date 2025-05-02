//AppUsageManager.swift
import Combine
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
    var logs: [AppUsageLog] = []
    var aggregatedResults: [AggregatedUsage] = []

    private var currentAppBundleId: String = ""
    private var currentAppName:      String = ""
    private var currentStartTime:    Date   = Date()
    private var isTracking:          Bool   = false

    private var recognizedAppUsage: [String: TimeInterval] = [:]
    private var currentRecognizedApp: String? = nil
    private var recognizedAppStart:    Date?  = nil

    private var faceDetected: Bool = false
    private var faceDetectCancellable: AnyCancellable?

    override init() { super.init() }
    deinit { stopWork() }

    func startWork(faceRecognitionManager: FaceRecognitionManager) {
        guard !isTracking else { return }
        isTracking = true

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

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

        if let frontApp = NSWorkspace.shared.frontmostApplication {
            let bundleId = frontApp.bundleIdentifier ?? "UnknownBundle"
            let appName  = frontApp.localizedName ?? "UnknownApp"
            print("最前面アプリ(開始時): \(appName), バンドルID: \(bundleId)")

            if !currentAppBundleId.isEmpty,
               let idx = logs.lastIndex(where: { $0.appName == currentAppName && $0.endTime == nil }) {
                logs[idx].endTime = Date()
            }

            currentAppBundleId = bundleId
            currentAppName     = appName
            currentStartTime   = Date()

            logs.append(AppUsageLog(bundleId: bundleId,
                                    appName:  appName,
                                    startTime: currentStartTime,
                                    endTime:   nil))

            stopRecognizedApp()
            if faceDetected { startRecognizedApp() }
        }
    }

    func stopWork() {
        guard isTracking else { return }

        NSWorkspace.shared.notificationCenter.removeObserver(
            self,
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        if !currentAppName.isEmpty,
           let idx = logs.lastIndex(where: { $0.appName == currentAppName && $0.endTime == nil }) {
            logs[idx].endTime = Date()
        }

        faceDetectCancellable?.cancel()
        faceDetectCancellable = nil
        faceDetected = false

        stopRecognizedApp()
        isTracking        = false
        currentAppBundleId = ""
        currentAppName     = ""
        currentStartTime   = Date()
    }

    @objc private func appDidActivate(_ notification: Notification) {
        guard isTracking,
              let runningApp = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }

        let bundleId = runningApp.bundleIdentifier ?? "UnknownBundle"
        let appName  = runningApp.localizedName ?? "UnknownApp"

        guard bundleId != currentAppBundleId else { return }

        print("最前面: \(appName), ID: \(bundleId)")

        if !currentAppName.isEmpty,
           let idx = logs.lastIndex(where: { $0.appName == currentAppName && $0.endTime == nil }) {
            logs[idx].endTime = Date()
        }

        currentAppBundleId = bundleId
        currentAppName     = appName
        currentStartTime   = Date()

        logs.append(AppUsageLog(bundleId: bundleId,
                                appName:  appName,
                                startTime: currentStartTime,
                                endTime:   nil))

        stopRecognizedApp()
        if faceDetected { startRecognizedApp() }
    }

    private func startRecognizedApp() {
        guard currentRecognizedApp == nil, !currentAppName.isEmpty else { return }
        currentRecognizedApp = currentAppName
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

    func saveCurrentUsageToDataStore() {
        calculateAggregatedUsage()
        aggregatedResults.removeAll()
    }
    
    func printRecognizedAppUsage() {
        stopRecognizedApp()
        recognizedAppUsage.removeAll()
    }

    func currentRecognizedAppUsageArray() -> [AppUsage] {
        stopRecognizedApp()
        let arr = recognizedAppUsage.map { AppUsage(name: $0.key, seconds: $0.value) }
        return arr
    }

    func snapshotRecognizedUsage() -> [String: TimeInterval] {
        stopRecognizedApp()
        return recognizedAppUsage
    }
    func clearRecognizedUsage() { recognizedAppUsage.removeAll() }
}
