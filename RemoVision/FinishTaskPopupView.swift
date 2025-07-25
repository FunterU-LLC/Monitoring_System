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
    
    @State private var currentIndex: Int = 0
    @State private var pressedIndex: Int? = nil
    
    @State private var hierarchicalTasks: [HierarchicalTask] = []
    @State private var expandedParents: Set<String> = []
    
    @FocusState private var focusedTaskId: String?
    @State private var taskComments: [String: String] = [:]
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        VStack {
            
            Text("作業完了するタスクを選択")
                .font(.headline)
                .foregroundColor(colorScheme == .dark ?
                    Color(red: 255/255, green: 224/255, blue: 153/255) :
                    Color(red: 92/255, green: 64/255, blue: 51/255))

            Text("未達成のタスクでもコメントを入力できます")
                .font(.caption)
                .foregroundColor(colorScheme == .dark ? .white.opacity(0.7) : .secondary)
            
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(hierarchicalTasks, id: \.id) { hierarchicalTask in
                        VStack(alignment: .leading, spacing: 0) {
                            hierarchicalTaskRow(
                                task: hierarchicalTask.task,
                                isParent: hierarchicalTask.isParent,
                                children: hierarchicalTask.children
                            )
                            
                            if hierarchicalTask.isParent && expandedParents.contains(hierarchicalTask.id) {
                                ForEach(hierarchicalTask.children) { childTask in
                                    hierarchicalTaskRow(
                                        task: childTask,
                                        isParent: false,
                                        children: [],
                                        isChild: true
                                    )
                                }
                            }
                        }
                    }
                }
                .animation(.easeInOut(duration: 0.3), value: expandedParents)
                .onTapGesture {
                    if focusedTaskId != nil {
                        focusedTaskId = nil
                    }
                }
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

                    let (parentWithChildren, standaloneParents) = analyzeTaskStructure(tasksToFinish)

                    let childTasks = tasksToFinish.filter { task in
                        !task.title.hasPrefix("&") || standaloneParents.contains(task.id)
                    }
                    let perTaskSeconds: Double = {
                        if childTasks.isEmpty {
                            return 0
                        } else {
                            return totalRecognized / Double(childTasks.count)
                        }
                    }()

                    let now = Date()
                    var currentParentName: String? = nil

                    let summaries: [TaskUsageSummary] = tasksToFinish.compactMap { task in
                        if task.title.hasPrefix("&") && parentWithChildren.contains(task.id) {
                            currentParentName = String(task.title.dropFirst())
                            return nil
                        }
                        
                        if task.title.hasPrefix("&") && standaloneParents.contains(task.id) {
                            currentParentName = nil
                        }
                        
                        let isDone = completedTasks.contains(task.id)
                        let note = taskComments[task.id]
                        
                        let taskName = task.title.hasPrefix("&") ? String(task.title.dropFirst()) : task.title
                        
                        let taskSeconds = perTaskSeconds
                        let st = now.addingTimeInterval(-taskSeconds)
                        
                        let apps: [AppUsage] = {
                            if usageDict.isEmpty {
                                return appUsageManager.currentRecognizedAppUsageArray()
                                    .map { AppUsage(name: $0.name, seconds: $0.seconds / Double(max(childTasks.count, 1))) }
                            } else {
                                return usageDict.map { AppUsage(name: $0.key, seconds: $0.value / Double(max(childTasks.count, 1))) }
                            }
                        }()
                        
                        let totalSec = apps.reduce(0) { $0 + $1.seconds }
                        
                        return TaskUsageSummary(
                            reminderId: task.id,
                            taskName: taskName,
                            isCompleted: isDone,
                            startTime: st,
                            endTime: now,
                            totalSeconds: totalSec,
                            comment: note,
                            appBreakdown: apps,
                            parentTaskName: task.title.hasPrefix("&") ? nil : currentParentName
                        )
                    }
                    
                    
                    Task {
                        let actualCompletedCount = summaries.filter { summary in
                            summary.isCompleted
                        }.count
                        
                        let sessionRecord = createSessionRecord(summaries: summaries, completedCount: actualCompletedCount)
                        await uploadToCloudKit(sessionRecord: sessionRecord)
                    }
                    
                    appUsageManager.clearRecognizedUsage()

                    for task in tasksToFinish {
                        if task.title.hasPrefix("&") && parentWithChildren.contains(task.id) {
                            continue
                        }
                        
                        let isDone = completedTasks.contains(task.id)
                        let note = taskComments[task.id]
                        remindersManager.updateTask(task, completed: isDone, notes: note)
                    }

                    faceRecognitionManager.stopCamera()
                    appUsageManager.stopWork()
                    appUsageManager.calculateAggregatedUsage()
                    appUsageManager.recognizedAppUsageFunc()
                    
                    appUsageManager.saveCurrentUsageToDataStore()

                    popupCoordinator.showFinishPopup = false
                    popupCoordinator.showWorkInProgress = false
                    popupCoordinator.showTaskStartPopup = false
                }
                .foregroundColor(colorScheme == .dark ? .white : .primary)
                .disabled(!completedTasks.isEmpty)
                .padding()
                
                Spacer()
                
                Button("完了") {
                    
                    let totalRecognized = faceRecognitionManager.endRecognitionSession()
                    let usageDict = appUsageManager.snapshotRecognizedUsage()
                    appUsageManager.stopWork()
                    appUsageManager.calculateAggregatedUsage()
                    
                    appUsageManager.recognizedAppUsageFunc()
                    appUsageManager.saveCurrentUsageToDataStore()
                    
                    
                    faceRecognitionManager.stopCamera()
                    
                    let (parentWithChildren, standaloneParents) = analyzeTaskStructure(tasksToFinish)

                    let childTasks = tasksToFinish.filter { task in
                        !task.title.hasPrefix("&") || standaloneParents.contains(task.id)
                    }
                    let perTaskSeconds: Double = {
                        if childTasks.isEmpty {
                            return 0
                        } else {
                            return totalRecognized / Double(childTasks.count)
                        }
                    }()

                    let now = Date()
                    var currentParentName: String? = nil

                    let summaries: [TaskUsageSummary] = tasksToFinish.compactMap { task in
                        if task.title.hasPrefix("&") && parentWithChildren.contains(task.id) {
                            currentParentName = String(task.title.dropFirst())
                            return nil
                        }
                        
                        if task.title.hasPrefix("&") && standaloneParents.contains(task.id) {
                            currentParentName = nil
                        }
                        
                        let isDone = completedTasks.contains(task.id)
                        let note = taskComments[task.id]
                        
                        let taskName = task.title.hasPrefix("&") ? String(task.title.dropFirst()) : task.title
                        
                        let taskSeconds = perTaskSeconds
                        let st = now.addingTimeInterval(-taskSeconds)
                        
                        let apps: [AppUsage] = {
                            if usageDict.isEmpty {
                                return appUsageManager.currentRecognizedAppUsageArray()
                                    .map { AppUsage(name: $0.name, seconds: $0.seconds / Double(max(childTasks.count, 1))) }
                            } else {
                                return usageDict.map { AppUsage(name: $0.key, seconds: $0.value / Double(max(childTasks.count, 1))) }
                            }
                        }()
                        
                        let totalSec = apps.reduce(0) { $0 + $1.seconds }
                        
                        return TaskUsageSummary(
                            reminderId: task.id,
                            taskName: taskName,
                            isCompleted: isDone,
                            startTime: st,
                            endTime: now,
                            totalSeconds: totalSec,
                            comment: note,
                            appBreakdown: apps,
                            parentTaskName: task.title.hasPrefix("&") ? nil : currentParentName
                        )
                    }
                    
                    appUsageManager.clearRecognizedUsage()
                    
                    Task {
                        let actualCompletedCount = summaries.filter { summary in
                            summary.isCompleted
                        }.count
                        
                        let sessionRecord = createSessionRecord(summaries: summaries, completedCount: actualCompletedCount)
                        await uploadToCloudKit(sessionRecord: sessionRecord)
                    }
                    
                    for task in tasksToFinish {
                        if task.title.hasPrefix("&") && parentWithChildren.contains(task.id) {
                            continue
                        }
                        
                        let isDone = completedTasks.contains(task.id)
                        let note = taskComments[task.id]
                        remindersManager.updateTask(task, completed: isDone, notes: note)
                    }
                        
                    popupCoordinator.showFinishPopup = false
                    popupCoordinator.showWorkInProgress = false
                    popupCoordinator.showTaskStartPopup = false
                }
                .foregroundColor(colorScheme == .dark ? .white : .primary)
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
                    
                    var newComments: [String: String] = [:]
                    for task in tasksToFinish {
                        newComments[task.id] = taskComments[task.id] ?? ""
                    }
                    taskComments = newComments
                    
                    buildHierarchicalStructure()
                    
                    if !tasksToFinish.isEmpty {
                        currentIndex = 0
                    }
                }
            }
        }
    }
    
    private func analyzeTaskStructure(_ tasks: [TaskItem]) -> (parentWithChildren: Set<String>, standaloneParents: Set<String>) {
        var parentWithChildren = Set<String>()
        var standaloneParents = Set<String>()
        
        for (index, task) in tasks.enumerated() {
            if task.title.hasPrefix("&") {
                let hasChildren = (index < tasks.count - 1) && !tasks[index + 1].title.hasPrefix("&")
                
                if hasChildren {
                    parentWithChildren.insert(task.id)
                } else {
                    standaloneParents.insert(task.id)
                }
            }
        }
        
        return (parentWithChildren, standaloneParents)
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
                },
                parentTaskName: summary.parentTaskName
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
            return
        }
        
        do {
            try await CloudKitService.shared.uploadSession(
                groupID: currentGroupID,
                userName: userName,
                sessionRecord: sessionRecord
            )
        } catch {
            await MainActor.run {
                let alert = NSAlert()
                alert.messageText = "アップロードエラー"
                alert.informativeText = "データをクラウドにアップロードできませんでした。\n\(error.localizedDescription)\n\nデータはローカルに保存されており、ネットワーク接続が回復した際に自動的にアップロードされます。"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
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
    
    private func buildHierarchicalStructure() {
        var result: [HierarchicalTask] = []
        var currentParent: HierarchicalTask? = nil
        var childrenBuffer: [TaskItem] = []
        
        for task in tasksToFinish {
            if task.title.hasPrefix("&") {
                if let parent = currentParent {
                    result.append(HierarchicalTask(
                        id: parent.id,
                        task: parent.task,
                        isParent: true,
                        children: childrenBuffer
                    ))
                }
                
                currentParent = HierarchicalTask(
                    id: task.id,
                    task: task,
                    isParent: true,
                    children: []
                )
                childrenBuffer = []
            } else {
                childrenBuffer.append(task)
            }
        }
        
        if let parent = currentParent {
            result.append(HierarchicalTask(
                id: parent.id,
                task: parent.task,
                isParent: true,
                children: childrenBuffer
            ))
        }
        
        hierarchicalTasks = result
        expandedParents = Set(result.filter { $0.isParent }.map { $0.id })
    }
    
    private func hierarchicalTaskRow(task: TaskItem, isParent: Bool, children: [TaskItem], isChild: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if isParent {
                    toggleParentAndChildren(task.id, children: children)
                } else {
                    toggleSelection(task.id)
                }
            } label: {
                HStack(spacing: 0) {
                    if isChild {
                        Spacer()
                            .frame(width: 24)
                    }
                    
                    if isParent {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                if expandedParents.contains(task.id) {
                                    expandedParents.remove(task.id)
                                } else {
                                    expandedParents.insert(task.id)
                                }
                            }
                        } label: {
                            Image(systemName: expandedParents.contains(task.id) ? "chevron.down" : "chevron.right")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                                .frame(width: 20, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    } else {
                        Spacer()
                            .frame(width: 20)
                    }
                    
                    Image(systemName: completedTasks.contains(task.id) ? "checkmark.square.fill" : "square")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(completedTasks.contains(task.id) ? .white : .primary,
                                       completedTasks.contains(task.id) ? .blue : .clear)
                        .padding(.leading, 8)
                    
                    VStack(alignment: .leading) {
                        Text(isParent ? "▼ \(String(task.title.dropFirst()))" : "・\(task.title)")
                            .fontWeight(isParent ? .semibold : .regular)
                            .foregroundColor(isParent ?
                                (colorScheme == .dark ?
                                    Color(red: 255/255, green: 224/255, blue: 153/255) :
                                    Color(red: 92/255, green: 64/255, blue: 51/255)) :
                                (colorScheme == .dark ? .white : .primary))

                        if let dueDate = task.dueDate {
                            Text("期限: \(dueDate, style: .date)")
                                .font(.caption)
                                .foregroundColor(colorScheme == .dark ? .white.opacity(0.7) : .secondary)
                        }
                    }
                    .padding(.leading, 8)
                    
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isParent ? Color(red: 255/255, green: 204/255, blue: 102/255).opacity(0.1) : Color.clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(
                Rectangle()
                    .fill(Color.gray.opacity(0.01))
                    .onHover { hovering in
                        if hovering {
                            NSCursor.pointingHand.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
            )
            
            Divider()
            
            if !isParent {
                VStack(alignment: .leading, spacing: 4) {
                    Text("コメント")
                        .font(.caption)
                        .foregroundColor(colorScheme == .dark ? .white.opacity(0.7) : .secondary)
                        .padding(.leading, isChild ? 44 : 0)
                    
                    TextField("コメントを入力してください(任意)", text: Binding(
                        get: { taskComments[task.id] ?? "" },
                        set: { newValue in
                            taskComments[task.id] = newValue
                        }
                    ), axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(3...5)
                    .font(.system(size: 13))
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.gray.opacity(colorScheme == .dark ? 0.2 : 0.05))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.gray.opacity(colorScheme == .dark ? 0.3 : 0.2), lineWidth: 1)
                            )
                    )
                    .frame(minHeight: 70)
                    .padding(.leading, isChild ? 44 : 0)
                }
                .padding(.bottom, 8)
            }
        }
    }
    
    private func toggleParentAndChildren(_ parentId: String, children: [TaskItem]) {
        if completedTasks.contains(parentId) {
            completedTasks.remove(parentId)
            for child in children {
                completedTasks.remove(child.id)
            }
        } else {
            completedTasks.insert(parentId)
            for child in children {
                completedTasks.insert(child.id)
            }
        }
    }
    
    private func toggleSelection(_ id: String) {
        if completedTasks.contains(id) {
            completedTasks.remove(id)
            if let parent = findParentTask(for: id) {
                let anyChildSelected = parent.children.contains { completedTasks.contains($0.id) }
                if !anyChildSelected {
                    completedTasks.remove(parent.id)
                }
            }
        } else {
            completedTasks.insert(id)
            
            if let parent = findParentTask(for: id) {
                completedTasks.insert(parent.id)
            }
        }
    }

    private func findParentTask(for childId: String) -> HierarchicalTask? {
        return hierarchicalTasks.first { hierarchicalTask in
            hierarchicalTask.isParent && hierarchicalTask.children.contains { $0.id == childId }
        }
    }
}

extension Binding where Value == String? {
    var bound: Binding<String> {
        Binding<String>(
            get: {
                self.wrappedValue ?? ""
            },
            set: { newValue in
                self.wrappedValue = newValue
            }
        )
    }
}
