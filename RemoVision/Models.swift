import SwiftUI

struct TaskItem: Identifiable {
    let id: String
    var title: String
    var dueDate: Date?
    var isCompleted: Bool
    var notes: String?
}

struct AppUsageLog: Identifiable {
    let id = UUID()
    let bundleId: String
    let appName: String
    let startTime: Date
    var endTime: Date?
}

struct AppUsage: Identifiable, Codable {
    let id: UUID = .init()
    let name: String
    let seconds: Double
    
    private enum CodingKeys: String, CodingKey {
        case name
        case seconds
    }
}

struct TaskUsageSummary: Identifiable, Codable {
    let id: UUID = .init()
    let reminderId: String
    let taskName:   String
    var isCompleted: Bool
    var startTime:   Date
    var endTime:     Date
    var totalSeconds: Double
    var comment: String?
    var appBreakdown: [AppUsage]
    var parentTaskName: String? = nil

    private enum CodingKeys: String, CodingKey {
        case reminderId, taskName,
             isCompleted, startTime, endTime,
             totalSeconds, comment, appBreakdown,
             parentTaskName
    }
}
