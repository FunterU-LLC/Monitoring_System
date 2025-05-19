import Foundation
import SwiftData

@Model
final class AppUsageModel {
    var name: String = ""
    var seconds: Double = 0.0
    
    @Relationship(inverse: \TaskUsageSummaryModel.appBreakdown) var task: TaskUsageSummaryModel?

    init(name: String, seconds: Double) {
        self.name = name
        self.seconds = seconds
    }
}

func resetSwiftDataStore() {
    let fileManager = FileManager.default
    let appSupportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    
    let monitoringSystemDir = appSupportDir.appendingPathComponent("MonitoringSystem")
    if fileManager.fileExists(atPath: monitoringSystemDir.path) {
        do {
            let contents = try fileManager.contentsOfDirectory(at: monitoringSystemDir, includingPropertiesForKeys: nil)
            for fileURL in contents {
                if fileURL.lastPathComponent.hasSuffix(".store") ||
                   fileURL.lastPathComponent.hasSuffix(".store-shm") ||
                   fileURL.lastPathComponent.hasSuffix(".store-wal") {
                    try fileManager.removeItem(at: fileURL)
                    print("削除しました: \(fileURL.path)")
                }
            }
        } catch {
            print("ファイル削除中のエラー: \(error)")
        }
    }
    
    if let containerURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: "FunterU.MonitoringSystem") {
        let containerAppSupportDir = containerURL.appendingPathComponent("Library/Application Support")
        let containerMonitoringDir = containerAppSupportDir.appendingPathComponent("MonitoringSystem")
        
        if fileManager.fileExists(atPath: containerMonitoringDir.path) {
            do {
                let contents = try fileManager.contentsOfDirectory(at: containerMonitoringDir, includingPropertiesForKeys: nil)
                for fileURL in contents {
                    if fileURL.lastPathComponent.hasSuffix(".store") ||
                       fileURL.lastPathComponent.hasSuffix(".store-shm") ||
                       fileURL.lastPathComponent.hasSuffix(".store-wal") {
                        try fileManager.removeItem(at: fileURL)
                        print("コンテナから削除しました: \(fileURL.path)")
                    }
                }
            } catch {
                print("コンテナファイル削除中のエラー: \(error)")
            }
        }
    }
}

@Model
final class TaskUsageSummaryModel {
    var reminderId: String = ""
    var taskName:   String = ""
    var isCompleted: Bool = false
    var startTime:   Date = Date()
    var endTime:     Date = Date()
    var totalSeconds: Double = 0.0
    var comment: String? = nil
    
    @Relationship(deleteRule: .cascade) var appBreakdown: [AppUsageModel]? = []
    
    @Relationship(inverse: \SessionRecordModel.taskSummaries) var session: SessionRecordModel?

    init(reminderId:   String,
         taskName:     String,
         isCompleted:  Bool,
         startTime:    Date,
         endTime:      Date,
         totalSeconds: Double,
         comment:      String? = nil,
         appBreakdown: [AppUsageModel]? = nil) {

        self.reminderId   = reminderId
        self.taskName     = taskName
        self.isCompleted  = isCompleted
        self.startTime    = startTime
        self.endTime      = endTime
        self.totalSeconds = totalSeconds
        self.comment      = comment
        self.appBreakdown = appBreakdown ?? []
    }
}

@Model
final class SessionRecordModel {
    var id: UUID = UUID()
    var endTime: Date = Date()
    
    @Relationship(deleteRule: .cascade) var taskSummaries: [TaskUsageSummaryModel]? = []
    var completedCount: Int = 0
    
    init(endTime: Date,
         taskSummaries: [TaskUsageSummaryModel]? = nil,
         completedCount: Int) {
        self.id            = UUID()
        self.endTime       = endTime
        self.taskSummaries = taskSummaries ?? []
        self.completedCount = completedCount
    }
}
