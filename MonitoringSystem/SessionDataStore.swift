//SessionDataStore.swift
import Foundation
import SwiftData

private struct LegacySessionRecord: Codable {
    let id: UUID
    let date: Date
    let taskSummaries: [TaskUsageSummary]
    let completedCount: Int
}

@MainActor
@Observable
final class SessionDataStore: ObservableObject {

    static let shared = SessionDataStore()

    let container: ModelContainer
    private let legacyURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
        return dir.appendingPathComponent("MonitoringSystem/sessions.json")
    }()
    var context: ModelContext { container.mainContext }

    var allSessions: [SessionRecordModel] = []

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

    func appendSession(tasks: [TaskUsageSummary], completed: Int) async {
        let taskModels: [TaskUsageSummaryModel] = tasks.map { t in
            TaskUsageSummaryModel(
                reminderId:  t.reminderId,
                taskName:    t.taskName,
                isCompleted: t.isCompleted,
                startTime:   t.startTime,
                endTime:     t.endTime,
                totalSeconds: t.totalSeconds,
                comment:     t.comment,
                appBreakdown: t.appBreakdown.map {
                    AppUsageModel(name: $0.name, seconds: $0.seconds)
                }
            )
        }
        
        let sessionEnd = tasks.map(\.endTime).max() ?? Date()
        let record = SessionRecordModel(endTime: sessionEnd,
                                        taskSummaries: taskModels,
                                        completedCount: completed)
        
        context.insert(record)
        try? context.save()
        await loadAll()
    }

    func summaries(forDays days: Int) async -> ([TaskUsageSummary], Int) {
        let cal          = Calendar.current
        let startOfToday = cal.startOfDay(for: Date())
        let from         = cal.date(byAdding: .day, value: -(days - 1), to: startOfToday)!
        
        let predicate = #Predicate<SessionRecordModel> { $0.endTime >= from }
        let sessions  = try! context.fetch(FetchDescriptor(predicate: predicate))
        
        var merged: [String: TaskUsageSummary] = [:]
        var completed = 0
        
        for s in sessions {
            completed += s.completedCount
            for ts in s.taskSummaries {
                let key = ts.reminderId.isEmpty ? ts.taskName : ts.reminderId
                if var hold = merged[key] {
                    hold.totalSeconds += ts.totalSeconds
                    hold.appBreakdown = merge(hold.appBreakdown,
                                              ts.appBreakdown.map {
                                                  AppUsage(name: $0.name, seconds: $0.seconds)
                                              })
                    hold.isCompleted = hold.isCompleted || ts.isCompleted
                    if hold.comment?.isEmpty ?? true, let c = ts.comment, !c.isEmpty {
                        hold.comment = c
                    }
                    hold.endTime     = max(hold.endTime,   ts.endTime)
                    hold.startTime   = min(hold.startTime, ts.startTime)
                    merged[key] = hold
                } else {
                    merged[key] = TaskUsageSummary(
                        reminderId:   ts.reminderId,
                        taskName:     ts.taskName,
                        isCompleted:  ts.isCompleted,
                        startTime:    ts.startTime,
                        endTime:      ts.endTime,
                        totalSeconds: ts.totalSeconds,
                        comment:      ts.comment,
                        appBreakdown: ts.appBreakdown.map {
                            AppUsage(name: $0.name, seconds: $0.seconds)
                        }
                    )
                }
            }
        }
        return (Array(merged.values), completed)
    }
    
    @MainActor
    func updateTaskCompletion(reminderId: String, isCompleted: Bool) {
        guard !reminderId.isEmpty else { return }

        let taskPredicate = #Predicate<TaskUsageSummaryModel> { $0.reminderId == reminderId }
        if let tasks = try? context.fetch(FetchDescriptor(predicate: taskPredicate)) {
            var changed = false
            for t in tasks where t.isCompleted != isCompleted {
                t.isCompleted = isCompleted
                changed = true
            }
            guard changed else { return }

            if let sessions = try? context.fetch(FetchDescriptor<SessionRecordModel>()) {
                for rec in sessions {
                    rec.completedCount = rec.taskSummaries.filter { $0.isCompleted }.count
                }
            }
            try? context.save()
            Task { await loadAll() }
        }
    }
    
    @MainActor
    func updateTaskTitle(reminderId: String, newTitle: String) {
        guard !reminderId.isEmpty else { return }
        let pred = #Predicate<TaskUsageSummaryModel> { $0.reminderId == reminderId }
        if let matched = try? context.fetch(FetchDescriptor(predicate: pred)) {
            matched.forEach { $0.taskName = newTitle }
            try? context.save()
            Task { await loadAll() }
        }
    }

    func resetAllSessions() async {
        for s in allSessions { context.delete(s) }
        try? context.save()
        await loadAll()
    }

    private func loadAll() async {
        let list = try! context.fetch(
            FetchDescriptor<SessionRecordModel>(sortBy: [SortDescriptor(\.endTime, order: .reverse)])
        )
        allSessions = list
    }

    private func merge(_ a:[AppUsage], _ b:[AppUsage]) -> [AppUsage] {
        var dict:[String:Double] = [:]
        (a+b).forEach { dict[$0.name, default:0] += $0.seconds }
        return dict.map { AppUsage(name:$0.key, seconds:$0.value) }
    }
    
    private func migrateLegacyJSONIfNeeded() {
        guard (try? context.fetch(FetchDescriptor<SessionRecordModel>()))?.isEmpty ?? true else { return }
        guard FileManager.default.fileExists(atPath: legacyURL.path) else { return }
        guard let data = try? Data(contentsOf: legacyURL),
              let legacy = try? JSONDecoder().decode([LegacySessionRecord].self, from: data) else { return }
        
        for rec in legacy {
            let taskModels = rec.taskSummaries.map { ts in
                TaskUsageSummaryModel(
                    reminderId:   ts.reminderId,
                    taskName:     ts.taskName,
                    isCompleted:  false,
                    startTime:    rec.date,
                    endTime:      rec.date,
                    totalSeconds: ts.totalSeconds,
                    comment:      nil,
                    appBreakdown: ts.appBreakdown.map {
                        AppUsageModel(name: $0.name, seconds: $0.seconds)
                    }
                )
            }
            let model = SessionRecordModel(endTime: rec.date,
                                           taskSummaries: taskModels,
                                           completedCount: rec.completedCount)
            context.insert(model)
        }
        try? context.save()
        try? FileManager.default.removeItem(at: legacyURL)
        Task { await loadAll() }
    }

    func wipeAllPersistentData() async {
        for record in allSessions { context.delete(record) }
        try? context.save()
        allSessions.removeAll()

        if let storeURL = container.configurations.first?.url {
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: storeURL.appendingPathExtension("shm"))
            try? FileManager.default.removeItem(at: storeURL.appendingPathExtension("wal"))
        }
        
        if FileManager.default.fileExists(atPath: legacyURL.path) {
            try? FileManager.default.removeItem(at: legacyURL)
        }
        print("✅ 端末保存データをすべて削除しました")
    }
    
    @MainActor
    func removeAllRecords(for reminderId: String) {
        guard !reminderId.isEmpty else { return }

        let predicate = #Predicate<TaskUsageSummaryModel> { $0.reminderId == reminderId }
        if let matched = try? context.fetch(FetchDescriptor(predicate: predicate)) {
            matched.forEach { context.delete($0) }
            try? context.save()
            Task { await loadAll() }
        }
    }
}
