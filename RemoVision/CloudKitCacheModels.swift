import Foundation
import SwiftData

@Model
final class CachedTaskSummary {
    var id: String = ""
    var groupID: String = ""
    var userName: String = ""
    var reminderId: String = ""
    var taskName: String = ""
    var isCompleted: Bool = false
    var startTime: Date = Date()
    var endTime: Date = Date()
    var totalSeconds: Double = 0.0
    var comment: String? = nil
    var parentTaskName: String? = nil
    var lastUpdated: Date = Date()
    var sessionEndTime: Date = Date()
    
    @Relationship(deleteRule: .cascade) var appBreakdown: [CachedAppUsage]? = []
    
    init(groupID: String, userName: String, reminderId: String, taskName: String,
         isCompleted: Bool, startTime: Date, endTime: Date, totalSeconds: Double,
         comment: String? = nil, parentTaskName: String? = nil, appBreakdown: [CachedAppUsage]? = nil,
         sessionEndTime: Date) {
        self.id = "\(groupID)_\(userName)_\(reminderId)_\(sessionEndTime.timeIntervalSince1970)"
        self.groupID = groupID
        self.userName = userName
        self.reminderId = reminderId
        self.taskName = taskName
        self.isCompleted = isCompleted
        self.startTime = startTime
        self.endTime = endTime
        self.totalSeconds = totalSeconds
        self.comment = comment
        self.parentTaskName = parentTaskName
        self.appBreakdown = appBreakdown ?? []
        self.lastUpdated = Date()
        self.sessionEndTime = sessionEndTime
    }
}

@Model
final class CachedAppUsage {
    var name: String = ""
    var seconds: Double = 0.0
    
    @Relationship(inverse: \CachedTaskSummary.appBreakdown) var task: CachedTaskSummary?
    
    init(name: String, seconds: Double) {
        self.name = name
        self.seconds = seconds
    }
}
