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

@Model
final class TaskUsageSummaryModel {
    var reminderId: String = ""
    var taskName:   String = ""
    var isCompleted: Bool = false
    var startTime:   Date = Date()
    var endTime:     Date = Date()
    var totalSeconds: Double = 0.0
    var comment: String? = nil
    var parentTaskName: String? = nil
    
    @Relationship(deleteRule: .cascade) var appBreakdown: [AppUsageModel]? = []
    
    @Relationship(inverse: \SessionRecordModel.taskSummaries) var session: SessionRecordModel?

    init(reminderId:   String,
         taskName:     String,
         isCompleted:  Bool,
         startTime:    Date,
         endTime:      Date,
         totalSeconds: Double,
         comment:      String? = nil,
         appBreakdown: [AppUsageModel]? = nil,
         parentTaskName: String? = nil) {

        self.reminderId   = reminderId
        self.taskName     = taskName
        self.isCompleted  = isCompleted
        self.startTime    = startTime
        self.endTime      = endTime
        self.totalSeconds = totalSeconds
        self.comment      = comment
        self.appBreakdown = appBreakdown ?? []
        self.parentTaskName = parentTaskName
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
