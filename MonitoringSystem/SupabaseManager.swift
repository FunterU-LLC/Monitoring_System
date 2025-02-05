//
//  SupabaseManager.swift
//  MonitoringSystemApp
//

import Foundation
import Network

/// ATTENTION: UI スレッドで直接プロパティを監視したい場合は
/// 別途 `@MainActor @Observable` のラッパーを作成してください。
actor SupabaseManager {

    // ────────── シングルトン ──────────
    static let shared = SupabaseManager()

    // ────────── ネットワーク監視 ──────────
    private let monitor      = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "NetworkMonitorQueue")

    private var isOnline: Bool = false

    // ────────── バッファリング ──────────
    private var attendanceLogBuffer: [AttendanceLog] = []
    private var appUsageLogBuffer:  [AppUsageLog]    = []

    private var syncTask: Task<Void, Never>? = nil

    // ────────── 初期化 / 解放 ──────────
    private init() {
        startNetworkMonitor()
        startSyncLoop()
    }
    deinit {
        monitor.cancel()
        syncTask?.cancel()
    }

    // ────────── 公開 API (すべて async) ──────────
    func currentOnlineStatus() -> Bool { isOnline }

    func sendAttendanceLog(_ log: AttendanceLog) async {
        if isOnline {
            print("Sending attendance log to Supabase immediately: \(log)")
            // TODO: 実際の送信処理を実装
        } else {
            attendanceLogBuffer.append(log)
            print("Offline: attendance log buffered: \(log)")
        }
    }

    func sendAppUsageLogs(_ logs: [AppUsageLog]) async {
        if isOnline {
            print("Sending \(logs.count) app usage logs to Supabase immediately.")
            // TODO: 実際の送信処理を実装
        } else {
            appUsageLogBuffer.append(contentsOf: logs)
            print("Offline: app usage logs buffered. Count=\(logs.count)")
        }
    }

    func fetchReports() async {
        if isOnline {
            print("Fetch reports from Supabase.")
            // TODO: 取得処理を実装
        } else {
            print("Cannot fetch reports (offline).")
        }
    }

    private func startNetworkMonitor() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { [weak self] in
                guard let self else { return }
                let wasOnline = await self.isOnline
                await self.setOnline(path.status == .satisfied)
                if await self.isOnline && !wasOnline {
                    await self.syncOfflineData()
                }
            }
        }
        monitor.start(queue: monitorQueue)
    }

    private func setOnline(_ value: Bool) {
        isOnline = value
    }

    private func startSyncLoop() {
        syncTask?.cancel()
        syncTask = Task.detached { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await self.syncOfflineData()
            }
        }
    }

    private func syncOfflineData() async {
        guard isOnline else { return }

        if !attendanceLogBuffer.isEmpty {
            print("Syncing offline attendance logs. Count=\(attendanceLogBuffer.count)")
            // TODO: 送信実装
            attendanceLogBuffer.removeAll()
        }
        if !appUsageLogBuffer.isEmpty {
            print("Syncing offline app usage logs. Count=\(appUsageLogBuffer.count)")
            // TODO: 送信実装
            appUsageLogBuffer.removeAll()
        }
    }
}

