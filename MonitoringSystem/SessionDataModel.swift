//
//  SessionDataModel.swift
//
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
    var taskName: String
    var totalSeconds: Double
    @Relationship(deleteRule: .cascade) var appBreakdown: [AppUsageModel] = []

    init(taskName: String,
         totalSeconds: Double,
         appBreakdown: [AppUsageModel] = []) {
        self.taskName     = taskName
        self.totalSeconds = totalSeconds
        self.appBreakdown = appBreakdown
    }
}

@Model
final class SessionRecordModel {
    @Attribute(.unique) var id: UUID
    var date: Date
    @Relationship(deleteRule: .cascade) var taskSummaries: [TaskUsageSummaryModel] = []
    var completedCount: Int

    init(date: Date,
         taskSummaries: [TaskUsageSummaryModel] = [],
         completedCount: Int) {
        self.id             = UUID()
        self.date           = date
        self.taskSummaries  = taskSummaries
        self.completedCount = completedCount
    }
}

