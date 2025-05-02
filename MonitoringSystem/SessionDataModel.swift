//SessionDataModel.swift
import Foundation
import SwiftData

@Model
final class AppUsageModel {
    var name: String
    var seconds: Double

    init(name: String, seconds: Double) {
        self.name = name
        self.seconds = seconds
    }
}

@Model
final class TaskUsageSummaryModel {
    var reminderId: String
    var taskName:   String
    var isCompleted: Bool
    var startTime:   Date
    var endTime:     Date
    var totalSeconds: Double
    var comment: String?
    @Relationship(deleteRule: .cascade) var appBreakdown: [AppUsageModel] = []

    init(reminderId:   String,
         taskName:     String,
         isCompleted:  Bool,
         startTime:    Date,
         endTime:      Date,
         totalSeconds: Double,
         comment:      String? = nil,
         appBreakdown: [AppUsageModel] = []) {

        self.reminderId   = reminderId
        self.taskName     = taskName
        self.isCompleted  = isCompleted
        self.startTime    = startTime
        self.endTime      = endTime
        self.totalSeconds = totalSeconds
        self.comment      = comment
        self.appBreakdown = appBreakdown
    }
}

@Model
final class SessionRecordModel {
    @Attribute(.unique) var id: UUID
    var endTime: Date
    @Relationship(deleteRule: .cascade) var taskSummaries: [TaskUsageSummaryModel] = []
    var completedCount: Int
    
    init(endTime: Date,
         taskSummaries: [TaskUsageSummaryModel] = [],
         completedCount: Int) {
        self.id            = UUID()
        self.endTime       = endTime
        self.taskSummaries = taskSummaries
        self.completedCount = completedCount
    }
}
