import SwiftUI
import AppKit

struct FinishTaskPopupView: View {
    @Environment(RemindersManager.self) var remindersManager
    @Environment(AppUsageManager.self) var appUsageManager
    @Environment(PopupCoordinator.self) var popupCoordinator
    @Environment(FaceRecognitionManager.self) var faceRecognitionManager

    @AppStorage("currentGroupID") private var currentGroupID: String = ""
    @AppStorage("userName") private var userName: String = ""

    let selectedTaskIds: [String]
    
    @State private var tasksToFinish: [TaskItem] = []
    @State private var completedTasks: Set<String> = []
    @State private var comments: [String: String] = [:]
    
    @State private var currentIndex: Int = 0
    @State private var pressedIndex: Int? = nil

    var body: some View {
        VStack {
            
            Text("作業完了するタスクを選択")
                .font(.headline)
            Text("未達成のタスクでもコメントを入力できます")
                .font(.caption)
                .foregroundColor(.secondary)
            
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(tasksToFinish.enumerated()), id: \.element.id) { i, task in
                        
                        Button(action: {
                            toggleSelection(task.id)
                        }) {
                            HStack {
                                if completedTasks.contains(task.id) {
                                    Image(systemName: "checkmark.square.fill")
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .blue)
                                } else {
                                    Image(systemName: "square")
                                        .symbolRenderingMode(.monochrome)
                                        .foregroundColor(.primary)
                                }
                                VStack(alignment: .leading) {
                                    Text(task.title)
                                    if let dueDate = task.dueDate {
                                        Text("期限: \(dueDate, style: .date)")
                                            .font(.caption)
                                    }
                                }
                                Spacer()
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                            .background(i == currentIndex ? Color.gray.opacity(0.2) : Color.clear)
                        }
                        .buttonStyle(HoverPressButtonStyle(overrideIsPressed: (i == pressedIndex)))
                        .onHover { inside in
                            if inside {
                                currentIndex = i
                            }
                        }
                        .transition(.slide)

                        Divider()
                        TextEditor(
                            text: Binding(
                                get: { comments[task.id, default: ""] },
                                set: { comments[task.id] = $0 }
                            )
                        )
                        .frame(height: 70)
                        .border(Color.gray.opacity(0.4))
                        .overlay(
                            Group {
                                if comments[task.id, default: ""].isEmpty {
                                    Text("コメントを入力してください(任意)")
                                        .foregroundColor(.secondary)
                                        .padding(.leading, 6)
                                        .padding(.top, 8)
                                }
                            },
                            alignment: .topLeading
                        )
                        .padding(.bottom, 8)
                    }
                }
                .animation(.easeInOut, value: tasksToFinish.map(\.id))
                .padding(.horizontal, 8)
            }
            .frame(minHeight: 200)
            
            HStack {
                Button("キャンセル") {
                    popupCoordinator.showFinishPopup = false
                }
                .padding()
                
                Spacer()
                
                Button("タスク未達成") {
                    let totalRecognized = faceRecognitionManager.endRecognitionSession()
                    let usageDict = appUsageManager.snapshotRecognizedUsage()

                    let perTaskSeconds: Double = {
                        if tasksToFinish.isEmpty { 0 } else { totalRecognized / Double(tasksToFinish.count) }
                    }()
                    let now = Date()
                    let summaries: [TaskUsageSummary] = tasksToFinish.map { task in
                        let isDone = completedTasks.contains(task.id)
                        let st = now.addingTimeInterval(-perTaskSeconds)
                        let note = comments[task.id]
                        let apps: [AppUsage] = usageDict.isEmpty
                            ? appUsageManager.currentRecognizedAppUsageArray()
                            : usageDict.map { AppUsage(name: $0.key, seconds: $0.value / Double(max(tasksToFinish.count,1))) }

                        let totalSec = apps.reduce(0) { $0 + $1.seconds }

                        return TaskUsageSummary(reminderId: task.id,
                                                taskName:   task.title,
                                                isCompleted: isDone,
                                                startTime:   st,
                                                endTime:     now,
                                                totalSeconds: totalSec,
                                                comment:      note,
                                                appBreakdown: apps)
                    }
                    
                    Task {
                        let sessionRecord = createSessionRecord(summaries: summaries, completedCount: 0)
                        await uploadToCloudKit(sessionRecord: sessionRecord)
                    }
                    
                    appUsageManager.clearRecognizedUsage()

                    for task in tasksToFinish {
                        if let note = comments[task.id], !note.isEmpty {
                            remindersManager.updateTask(task, completed: false, notes: note)
                        }
                    }

                    faceRecognitionManager.stopCamera()
                    appUsageManager.stopWork()
                    appUsageManager.calculateAggregatedUsage()
                    appUsageManager.printRecognizedAppUsage()
                    
                    appUsageManager.saveCurrentUsageToDataStore()

                    popupCoordinator.showFinishPopup = false
                    popupCoordinator.showWorkInProgress = false
                    popupCoordinator.showTaskStartPopup = false
                }
                
                .disabled(!completedTasks.isEmpty)
                .padding()
                
                Spacer()
                
                Button("完了") {
                    
                    let totalRecognized = faceRecognitionManager.endRecognitionSession()
                    let usageDict = appUsageManager.snapshotRecognizedUsage()
                    let totalAppSeconds = usageDict.values.reduce(0, +)
                    appUsageManager.stopWork()
                    appUsageManager.calculateAggregatedUsage()
                    
                    appUsageManager.printRecognizedAppUsage()
                    appUsageManager.saveCurrentUsageToDataStore()
                    
                    for task in tasksToFinish {
                        let isDone = completedTasks.contains(task.id)
                        let note   = comments[task.id]
                        remindersManager.updateTask(task, completed: isDone, notes: note)
                    }
                    
                    faceRecognitionManager.stopCamera()
                    
                    let perTaskSeconds: Double = {
                        if totalRecognized > 0 {
                            return totalRecognized / Double(max(tasksToFinish.count, 1))
                        } else {
                            return totalAppSeconds / Double(max(tasksToFinish.count, 1))
                        }
                    }()

                    let now = Date()
                    let summaries: [TaskUsageSummary] = tasksToFinish.map { task in
                        let isDone = completedTasks.contains(task.id)
                        
                        let note = comments[task.id]
                        let apps: [AppUsage] = {
                            if !usageDict.isEmpty {
                                return usageDict.map { name, sec in
                                    let seconds: Double
                                    if totalRecognized > 0 && totalAppSeconds > 0 {
                                        seconds = (sec / totalAppSeconds) * perTaskSeconds
                                    } else {
                                        seconds = sec / Double(max(tasksToFinish.count, 1))
                                    }
                                    return AppUsage(name: name, seconds: seconds)
                                }
                            } else {
                                let current = appUsageManager.currentRecognizedAppUsageArray()
                                return current.map { app in
                                    AppUsage(name: app.name,
                                             seconds: app.seconds / Double(max(tasksToFinish.count, 1)))
                                }
                            }
                        }()

                        let totalSec = apps.reduce(0) { $0 + $1.seconds }
                        let start   = now.addingTimeInterval(-perTaskSeconds)

                        return TaskUsageSummary(
                            reminderId:  task.id,
                            taskName:    task.title,
                            isCompleted: isDone,
                            startTime:   start,
                            endTime:     now,
                            totalSeconds: totalSec,
                            comment:      note,
                            appBreakdown: apps
                        )
                    }
                    
                    appUsageManager.clearRecognizedUsage()
                    
                    Task {
                        let sessionRecord = createSessionRecord(summaries: summaries, completedCount: completedTasks.count)
                        await uploadToCloudKit(sessionRecord: sessionRecord)
                    }
                        
                    popupCoordinator.showFinishPopup = false
                    popupCoordinator.showWorkInProgress = false
                    popupCoordinator.showTaskStartPopup = false
                }
                
                .disabled(completedTasks.isEmpty)
                .padding()
            }
        }
        .padding()
        .overlay(
            KeyboardMonitorView { event in
                handleKeyDown(event)
            }
            .allowsHitTesting(false)
        )
        
        .onAppear {
            remindersManager.fetchTasks(for: remindersManager.selectedList) { updatedTasks in
                DispatchQueue.main.async {
                    tasksToFinish = updatedTasks.filter { selectedTaskIds.contains($0.id) }
                    if !tasksToFinish.isEmpty {
                        currentIndex = 0
                    }
                }
            }
        }
    }
    
    private func createSessionRecord(summaries: [TaskUsageSummary], completedCount: Int) -> SessionRecordModel {
        let taskModels = summaries.map { summary in
            TaskUsageSummaryModel(
                reminderId: summary.reminderId,
                taskName: summary.taskName,
                isCompleted: summary.isCompleted,
                startTime: summary.startTime,
                endTime: summary.endTime,
                totalSeconds: summary.totalSeconds,
                comment: summary.comment,
                appBreakdown: summary.appBreakdown.map { app in
                    AppUsageModel(name: app.name, seconds: app.seconds)
                }
            )
        }
        
        let sessionEnd = summaries.map(\.endTime).max() ?? Date()
        return SessionRecordModel(
            endTime: sessionEnd,
            taskSummaries: taskModels,
            completedCount: completedCount
        )
    }
    
    private func uploadToCloudKit(sessionRecord: SessionRecordModel) async {
        guard !currentGroupID.isEmpty && !userName.isEmpty else {
            print("❌ Cannot upload: Missing groupID or userName")
            return
        }
        
        do {
            print("📤 Uploading session to CloudKit...")
            try await CloudKitService.shared.uploadSession(
                groupID: currentGroupID,
                userName: userName,
                sessionRecord: sessionRecord
            )
            print("✅ Session uploaded successfully")
        } catch {
            print("❌ Failed to upload session: \(error.localizedDescription)")
        }
    }
    
    private func handleKeyDown(_ event: NSEvent) {
        if let firstResponder = NSApp.keyWindow?.firstResponder,
           firstResponder is NSTextView {
            return
        }
        switch event.keyCode {
        case 125:
            moveDown()
        case 126:
            moveUp()
        case 49:
            withAnimation(.easeInOut(duration: 0.1)) {
                pressedIndex = currentIndex
            }
            toggleCheckAndMoveDown()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                withAnimation(.easeInOut(duration: 0.1)) {
                    pressedIndex = nil
                }
            }
        default:
            break
        }
    }
    
    private func moveUp() {
        if currentIndex > 0 {
            currentIndex -= 1
        }
    }
    
    private func moveDown() {
        if currentIndex < tasksToFinish.count - 1 {
            currentIndex += 1
        }
    }
    
    private func toggleCheckAndMoveDown() {
        guard currentIndex < tasksToFinish.count else { return }
        let (i, task) = (currentIndex, tasksToFinish[currentIndex])
        
        toggleSelection(task.id)
        
        if completedTasks.contains(task.id), i < tasksToFinish.count - 1 {
            currentIndex += 1
        }
    }
    private func toggleSelection(_ id: String) {
        if completedTasks.contains(id) {
            completedTasks.remove(id)
        } else {
            completedTasks.insert(id)
        }
    }
}
