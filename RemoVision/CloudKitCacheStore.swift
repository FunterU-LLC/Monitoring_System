import Foundation
import SwiftData
import CloudKit

@MainActor
final class CloudKitCacheStore {
    static let shared = CloudKitCacheStore()
    private let maxRecords = 10000
    
    let container: ModelContainer
    var context: ModelContext { container.mainContext }
    
    private init() {
        let schema = Schema([
            CachedTaskSummary.self,
            CachedAppUsage.self
        ])
        
        do {
            let url = URL.applicationSupportDirectory.appending(path: "CloudKitCache.sqlite")
            let config = ModelConfiguration(url: url, cloudKitDatabase: .none)
            container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("CloudKitCacheStoreの初期化に失敗: \(error)")
        }
    }
    
    func saveToken(_ token: CKServerChangeToken?, for key: String) {
        guard let token = token else { return }
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) {
            UserDefaults.standard.set(data, forKey: "CKChangeToken_\(key)")
        }
    }
    
    func loadToken(for key: String) -> CKServerChangeToken? {
        guard let data = UserDefaults.standard.data(forKey: "CKChangeToken_\(key)"),
              let token = try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data) else {
            return nil
        }
        return token
    }
    
    func saveTaskSummaries(_ summaries: [TaskUsageSummary], groupID: String, userName: String, sessionEndTime: Date) async {
        for summary in summaries {
            let cachedApps = summary.appBreakdown.map { app in
                CachedAppUsage(name: app.name, seconds: app.seconds)
            }
            
            let cachedTask = CachedTaskSummary(
                groupID: groupID,
                userName: userName,
                reminderId: summary.reminderId,
                taskName: summary.taskName,
                isCompleted: summary.isCompleted,
                startTime: summary.startTime,
                endTime: summary.endTime,
                totalSeconds: summary.totalSeconds,
                comment: summary.comment,
                parentTaskName: summary.parentTaskName,
                appBreakdown: cachedApps,
                sessionEndTime: sessionEndTime
            )
            
            context.insert(cachedTask)
        }
        
        try? context.save()
        await enforceRecordLimit()
    }
    
    func loadCachedSummaries(groupID: String, userName: String, forDays days: Int) async -> [TaskUsageSummary] {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let fromDate = calendar.date(byAdding: .day, value: -(days - 1), to: startOfToday)!
        
        let predicate = #Predicate<CachedTaskSummary> {
            $0.groupID == groupID &&
            $0.userName == userName &&
            $0.endTime >= fromDate
        }
        
        let cached = try! context.fetch(FetchDescriptor(predicate: predicate))
        
        var merged: [String: TaskUsageSummary] = [:]
        
        for task in cached {
            let key = task.reminderId.isEmpty ? task.taskName : task.reminderId
            
            let appUsages = (task.appBreakdown ?? []).map { app in
                AppUsage(name: app.name, seconds: app.seconds)
            }
            
            if var existing = merged[key] {
                existing.totalSeconds += task.totalSeconds
                existing.appBreakdown = mergeAppUsage(existing.appBreakdown, appUsages)
                existing.isCompleted = existing.isCompleted || task.isCompleted
                
                if existing.comment?.isEmpty ?? true, let newComment = task.comment, !newComment.isEmpty {
                    existing.comment = newComment
                }
                
                if existing.parentTaskName == nil, let newParentTaskName = task.parentTaskName {
                    existing.parentTaskName = newParentTaskName
                }
                
                existing.endTime = max(existing.endTime, task.endTime)
                existing.startTime = min(existing.startTime, task.startTime)
                
                merged[key] = existing
            } else {
                merged[key] = TaskUsageSummary(
                    reminderId: task.reminderId,
                    taskName: task.taskName,
                    isCompleted: task.isCompleted,
                    startTime: task.startTime,
                    endTime: task.endTime,
                    totalSeconds: task.totalSeconds,
                    comment: task.comment,
                    appBreakdown: appUsages,
                    parentTaskName: task.parentTaskName
                )
            }
        }
        
        return Array(merged.values)
    }
    
    func clearCache(for groupID: String, userName: String) async {
        let predicate = #Predicate<CachedTaskSummary> {
            $0.groupID == groupID && $0.userName == userName
        }
        
        let toDelete = try! context.fetch(FetchDescriptor(predicate: predicate))
        for item in toDelete {
            context.delete(item)
        }
        
        try? context.save()
        
        let tokenKey = "\(groupID)_\(userName)"
        UserDefaults.standard.removeObject(forKey: "CKChangeToken_\(tokenKey)")
    }
    
    func clearAllCache() async {
        let all = try! context.fetch(FetchDescriptor<CachedTaskSummary>())
        for item in all {
            context.delete(item)
        }
        try? context.save()
        
        let keys = UserDefaults.standard.dictionaryRepresentation().keys.filter { $0.hasPrefix("CKChangeToken_") }
        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
    
    private func enforceRecordLimit() async {
        let descriptor = FetchDescriptor<CachedTaskSummary>(
            sortBy: [SortDescriptor(\.lastUpdated, order: .reverse)]
        )
        let all = try! context.fetch(descriptor)
        
        if all.count > maxRecords {
            let toDelete = Array(all.suffix(from: maxRecords))
            for item in toDelete {
                context.delete(item)
            }
            try? context.save()
        }
    }
    
    private func mergeAppUsage(_ existing: [AppUsage], _ new: [AppUsage]) -> [AppUsage] {
        var merged: [String: Double] = [:]
        
        for app in existing {
            merged[app.name, default: 0] += app.seconds
        }
        
        for app in new {
            merged[app.name, default: 0] += app.seconds
        }
        
        return merged.map { AppUsage(name: $0.key, seconds: $0.value) }
    }
}
