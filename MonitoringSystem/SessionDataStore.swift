//
//  SessionDataStore.swift (SwiftData版)
//
import Foundation
import SwiftData

// MARK: - Legacy JSON structs (used only for migration)
private struct LegacySessionRecord: Codable {
    let id: UUID
    let date: Date
    let taskSummaries: [TaskUsageSummary]
    let completedCount: Int
}

@MainActor
final class SessionDataStore: ObservableObject {

    static let shared = SessionDataStore()

    let container: ModelContainer
    /// 旧 JSON 保存先
    private let legacyURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
        return dir.appendingPathComponent("MonitoringSystem/sessions.json")
    }()
    var context: ModelContext { container.mainContext }

    @Published private(set) var allSessions: [SessionRecordModel] = []

    private init() {
        let schema = Schema([
            SessionRecordModel.self,
            TaskUsageSummaryModel.self,
            AppUsageModel.self
        ])
        container = try! ModelContainer(for: schema,
                                        configurations: [.init(isStoredInMemoryOnly: false)])
        migrateLegacyJSONIfNeeded()
        Task { await loadAll() }
    }

    // ────────── 公開 API ──────────
    func appendSession(tasks: [TaskUsageSummary],
                       completed: Int) async {

        let taskModels: [TaskUsageSummaryModel] = tasks.map { t in
            TaskUsageSummaryModel(
                taskName: t.taskName,
                totalSeconds: t.totalSeconds,
                appBreakdown: t.appBreakdown.map {
                    AppUsageModel(name: $0.name, seconds: $0.seconds)
                }
            )
        }
        let record = SessionRecordModel(date: Date(),
                                        taskSummaries: taskModels,
                                        completedCount: completed)
        context.insert(record)
        try? context.save()
        await loadAll()
    }

    /// 直近 `days` 日の集計
    func summaries(forDays days: Int) async -> ([TaskUsageSummary], Int) {
        let from = Calendar.current.date(byAdding: .day, value: -days + 1, to: Date())!
        let predicate = #Predicate<SessionRecordModel> { $0.date >= from }
        let sessions = try! context.fetch(FetchDescriptor(predicate: predicate))
        var merged: [String: TaskUsageSummary] = [:]
        var completed = 0

        for s in sessions {
            completed += s.completedCount
            for ts in s.taskSummaries {
                if var hold = merged[ts.taskName] {
                    hold.totalSeconds += ts.totalSeconds
                    hold.appBreakdown = merge(hold.appBreakdown,
                                              ts.appBreakdown.map { .init(name:$0.name, seconds:$0.seconds) })
                    merged[ts.taskName] = hold
                } else {
                    merged[ts.taskName] = TaskUsageSummary(
                        taskName: ts.taskName,
                        totalSeconds: ts.totalSeconds,
                        appBreakdown: ts.appBreakdown.map { .init(name:$0.name, seconds:$0.seconds) })
                }
            }
        }
        return (Array(merged.values), completed)
    }

    func resetAllSessions() async {
        for s in allSessions { context.delete(s) }
        try? context.save()
        await loadAll()
    }

    // ────────── 内部
    private func loadAll() async {
        let list = try! context.fetch(FetchDescriptor<SessionRecordModel>())
        allSessions = list.sorted { $0.date > $1.date }
    }

    private func merge(_ a:[AppUsage], _ b:[AppUsage]) -> [AppUsage] {
        var dict:[String:Double] = [:]
        (a+b).forEach { dict[$0.name, default:0] += $0.seconds }
        return dict.map { AppUsage(name:$0.key, seconds:$0.value) }
    }
    
    // MARK: - Legacy JSON → SwiftData migration (one-shot)
    private func migrateLegacyJSONIfNeeded() {
        // 既にセッションが存在する場合は移行不要
        guard (try? context.fetch(FetchDescriptor<SessionRecordModel>()))?.isEmpty ?? true else { return }
        guard FileManager.default.fileExists(atPath: legacyURL.path) else { return }
        guard let data = try? Data(contentsOf: legacyURL),
              let legacy = try? JSONDecoder().decode([LegacySessionRecord].self, from: data) else { return }

        for rec in legacy {
            let taskModels = rec.taskSummaries.map { ts in
                TaskUsageSummaryModel(
                    taskName: ts.taskName,
                    totalSeconds: ts.totalSeconds,
                    appBreakdown: ts.appBreakdown.map {
                        AppUsageModel(name: $0.name, seconds: $0.seconds)
                    })
            }
            let model = SessionRecordModel(date: rec.date,
                                           taskSummaries: taskModels,
                                           completedCount: rec.completedCount)
            context.insert(model)
        }
        try? context.save()
        try? FileManager.default.removeItem(at: legacyURL)   // 移行後に旧ファイルを削除
        Task { await loadAll() }                             // @Published を更新
    }
    // MARK: - すべての端末保存データを削除
    /// ・SwiftData コンテナ内レコードを削除
    /// ・SQLite ファイル本体 & -shm / -wal を削除
    /// ・旧 JSON バックアップが残っていれば削除
    func wipeAllPersistentData() async {

        // 1) SwiftData レコードを全削除
        for record in allSessions { context.delete(record) }
        try? context.save()
        allSessions.removeAll()

        // 2) SQLite ファイル自体を削除（次回起動時に再生成される）
        if let storeURL = container.configurations.first?.url {
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: storeURL.appendingPathExtension("shm"))
            try? FileManager.default.removeItem(at: storeURL.appendingPathExtension("wal"))
        }

        // 3) 旧 JSON が残っていれば削除
        if FileManager.default.fileExists(atPath: legacyURL.path) {
            try? FileManager.default.removeItem(at: legacyURL)
        }

        print("✅ 端末保存データをすべて削除しました")
    }
}

