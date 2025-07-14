import SwiftUI

struct User: Identifiable {
    let id: String
    var name: String
    var isPresent: Bool
}

struct TaskItem: Identifiable {
    let id: String
    var title: String
    var dueDate: Date?
    var isCompleted: Bool
    var notes: String?
    var subtasks: [TaskItem] = []
}

struct AppUsageLog: Identifiable {
    let id = UUID()
    let bundleId: String
    let appName: String
    let startTime: Date
    var endTime: Date?
}

struct AttendanceLog: Identifiable {
    let id = UUID()
    let userId: String
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

    private enum CodingKeys: String, CodingKey {
        case reminderId, taskName,
             isCompleted, startTime, endTime,
             totalSeconds, comment, appBreakdown
    }
}

struct TaskAppBarDatum: Identifiable {
    let id = UUID()
    let taskName: String
    let appName:  String
    let seconds:  Double
}

struct TaskRowView: View {
    let task: TaskItem
    @Binding var selectedTaskIds: Set<String>
    @State private var isExpanded: Bool = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if !task.subtasks.isEmpty {
                    Button { isExpanded.toggle() } label: {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .foregroundColor(.blue)
                    }
                } else {
                    Spacer().frame(width: 20)
                }
                
                Image(systemName: selectedTaskIds.contains(task.id) ? "checkmark.square" : "square")
                    .onTapGesture { toggleSelection(task.id) }
                
                VStack(alignment: .leading) {
                    Text(task.title)
                    if let due = task.dueDate {
                        Text("期限: \(due, style: .date)")
                            .font(.caption).foregroundColor(.gray)
                    }
                }
            }
            .padding(.vertical, 4)
            
            if isExpanded {
                ForEach(task.subtasks) { sub in
                    HStack {
                        Spacer().frame(width: 20)
                        TaskRowView(task: sub, selectedTaskIds: $selectedTaskIds)
                    }
                }
            }
            Divider()
        }
    }
    
    private func toggleSelection(_ id: String) {
        if selectedTaskIds.contains(id) { selectedTaskIds.remove(id) }
        else { selectedTaskIds.insert(id) }
    }
}
