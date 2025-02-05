import Foundation
import SwiftData

/// すべての I/O と永続化を直列化して扱うバックエンド
actor SessionDataBackend {

    // ────── Singleton ──────
    static let shared = SessionDataBackend()

    // ────── SwiftData コンテナ ──────
    private let container: ModelContainer
    private var context: ModelContext { container.mainContext }

    private init() {
        let schema = Schema([
            SessionRecordModel.self,
            TaskUsageSummaryModel.self,
            AppUsageModel.self
        ])
        container = try! ModelContainer(for: schema,
                                        configurations: [.init(isStoredInMemoryOnly: false)])
    }

    // MARK: -- Public API (すべて async) --
    func fetchAll() async -> [SessionRecordModel] {
        try! context.fetch(FetchDescriptor<SessionRecordModel>())
            .sorted { $0.date > $1.date }
    }

    func appendSession(tasks: [TaskUsageSummary],
                       completed: Int) async {

        let taskModels = tasks.map { t in
            TaskUsageSummaryModel(
                taskName: t.taskName,
                totalSeconds: t.totalSeconds,
                appBreakdown: t.appBreakdown.map {
                    AppUsageModel(name: $0.name, seconds: $0.seconds)
                })
        }
        let record = SessionRecordModel(date: Date(),
                                        taskSummaries: taskModels,
                                        completedCount: completed)
        context.insert(record)
        try? context.save()
    }

    func summaries(forDays days: Int) async -> ([TaskUsageSummary], Int) {
        let from = Calendar.current.date(byAdding: .day, value: -days + 1, to: .now)!
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

    func wipeAll() async {
        for rec in try! context.fetch(FetchDescriptor<SessionRecordModel>()) {
            context.delete(rec)
        }
        try? context.save()

        if let url = container.configurations.first?.url {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.appendingPathExtension("shm"))
            try? FileManager.default.removeItem(at: url.appendingPathExtension("wal"))
        }
    }

    // MARK: -- helpers --
    private func merge(_ a:[AppUsage], _ b:[AppUsage]) -> [AppUsage] {
        var dict:[String:Double] = [:]
        (a+b).forEach { dict[$0.name, default:0] += $0.seconds }
        return dict.map { AppUsage(name:$0.key, seconds:$0.value) }
    }
}
