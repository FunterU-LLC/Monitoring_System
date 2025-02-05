import SwiftUI
import AppKit

struct FinishTaskPopupView: View {
    @Environment(RemindersManager.self) var remindersManager
    @Environment(AppUsageManager.self) var appUsageManager
    @Environment(PopupCoordinator.self) var popupCoordinator
    @Environment(FaceRecognitionManager.self) var faceRecognitionManager

    let selectedTaskIds: [String]
    
    @State private var tasksToFinish: [TaskItem] = []
    @State private var completedTasks: Set<String> = []
    @State private var comment: String = ""
    
    @State private var currentIndex: Int = 0
    @State private var pressedIndex: Int? = nil

    var body: some View {
        VStack {
            
            Text("作業完了するタスクを選択")
                .font(.headline)
            
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
                    }
                }
                .animation(.easeInOut, value: tasksToFinish.map(\.id))
                .padding(.horizontal, 8)
            }
            .frame(minHeight: 200)
            
            Text("コメント(複数行)")
                .font(.subheadline)
            TextEditor(text: $comment)
                .border(Color.gray, width: 1)
                .frame(height: 80)
            
            HStack {
                Button("キャンセル") {
                    popupCoordinator.showFinishPopup = false
                }
                .padding()
                
                Spacer()
                
                Button("タスク未達成") {
                    let totalRecognized = faceRecognitionManager.endRecognitionSession()
                    let usageDict = appUsageManager.snapshotRecognizedUsage()
                    let appBreak = usageDict.map { AppUsage(name: $0.key, seconds: $0.value) }

                    let summary = TaskUsageSummary(taskName: "Unfinished",
                                                   totalSeconds: totalRecognized,
                                                   appBreakdown: appBreak)
                    Task { await SessionDataStore.shared.appendSession(tasks: [summary], completed: 0) }
                    appUsageManager.clearRecognizedUsage()

                    faceRecognitionManager.stopCamera()
                    appUsageManager.stopWork()
                    appUsageManager.calculateAggregatedUsage()
                    appUsageManager.printRecognizedAppUsage()

                    popupCoordinator.showFinishPopup = false
                    popupCoordinator.showWorkInProgress = false
                    popupCoordinator.showTaskStartPopup = false
                }
                
                .disabled(!completedTasks.isEmpty)
                .padding()
                
                Spacer()
                
                Button("完了") {
                    
                    let totalRecognized = faceRecognitionManager.endRecognitionSession()
                    let numberOfTasks = tasksToFinish.count
                    if numberOfTasks > 0 {
                        let perTask = totalRecognized / Double(numberOfTasks)
                        print("----- 作業時間計測結果 -----")
                        print("合計で \(totalRecognized) 秒 顔を検出。")
                        print("選択中タスク数 = \(numberOfTasks)。各タスク = \(perTask) 秒として記録。")
                    } else {
                        print("タスクが0件。計 \(totalRecognized) 秒計測しましたが割り当て先なし。")
                    }
                    
                    appUsageManager.printRecognizedAppUsage()
                    
                    for tId in completedTasks {
                        if let task = tasksToFinish.first(where: { $0.id == tId }) {
                            remindersManager.updateTask(task, completed: true, notes: comment)
                        }
                    }
                    
                    faceRecognitionManager.stopCamera()
                    let usageDict = appUsageManager.snapshotRecognizedUsage()
                    let totalAppSeconds = usageDict.values.reduce(0, +)
                    appUsageManager.stopWork()
                    appUsageManager.calculateAggregatedUsage()
                    
                    let perTaskSeconds: Double = {
                        if totalRecognized > 0 {
                            return totalRecognized / Double(max(tasksToFinish.count, 1))
                        } else {
                            return totalAppSeconds / Double(max(tasksToFinish.count, 1))
                        }
                    }()

                    let summaries: [TaskUsageSummary] = tasksToFinish.map { task in
                        let apps: [AppUsage] = usageDict.map { name, sec in
                            let seconds: Double
                            if totalRecognized > 0 && totalAppSeconds > 0 {
                                seconds = (sec / totalAppSeconds) * perTaskSeconds
                            } else {
                                seconds = sec / Double(max(tasksToFinish.count, 1))
                            }
                            return AppUsage(name: name, seconds: seconds)
                        }
                        
                        let totalSec = apps.reduce(0) { $0 + $1.seconds }
                        
                        return TaskUsageSummary(taskName: task.title,
                                                totalSeconds: totalSec,
                                                appBreakdown: apps)
                    }
                    appUsageManager.clearRecognizedUsage()
                    Task { await SessionDataStore.shared.appendSession(tasks: summaries,
                                                                       completed: completedTasks.count) }
                    
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

extension FinishTaskPopupView {
    private func fallbackFrontmostApp(seconds: Double) -> AppUsage {
        let front = NSWorkspace.shared.frontmostApplication
        let name  = front?.localizedName ?? "UnknownApp"
        return AppUsage(name: name, seconds: seconds)
    }

}

