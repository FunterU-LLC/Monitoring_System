import AppKit
import SwiftUI
import Combine

struct TaskStartPopupView: View {
    @Environment(RemindersManager.self) var remindersManager
    @Environment(AppUsageManager.self) var appUsageManager
    @Environment(PopupCoordinator.self) var popupCoordinator
    @Environment(FaceRecognitionManager.self) var faceRecognitionManager
    @Environment(CameraManager.self) var cameraManager

    @State private var selectedTaskIds: Set<String> = []
    @State private var showAddTaskSuccess: Bool = false
    @State private var currentIndex: Int = 0
    @State private var displayedTasks: [TaskItem] = []
    @State private var pressedIndex: Int? = nil
    @State private var selectedTaskIdsByList: [String: Set<String>] = [:]
    @State private var showDeleteAlert: Bool = false
    @State private var isCancelDefault: Bool = true
    @State private var showStartAlert: Bool = false
    @State private var isCancelDefaultForStart: Bool = true
    @State private var reminderAccessError: String? = nil
    @State private var reminderSubscriptions: Set<AnyCancellable> = []
    @State private var showReminderSettingsPrompt = false
    @State private var showCameraSettingsPrompt = false
    @State private var hierarchicalTasks: [HierarchicalTask] = []
    @State private var expandedParents: Set<String> = []
    @State private var pressedTaskId: String? = nil
    
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        VStack(alignment: .leading) {
            headerSection
            
            taskListSection
            
            addTaskButtonSection
            
            Divider()
            
            actionButtonsSection
        }
        .frame(minWidth: 500, minHeight: 500)
        .padding()
        .sheet(isPresented: Binding(
            get: { popupCoordinator.showWorkInProgress },
            set: { popupCoordinator.showWorkInProgress = $0 }
        )) {
            WorkInProgressView(selectedTaskIds: Array(selectedTaskIds))
                .environment(faceRecognitionManager)
                .environment(cameraManager)
                .environment(popupCoordinator)
                .environment(remindersManager)
        }
        .background(
            KeyboardMonitorView { event in
                handleKeyDown(event)
            }
            .allowsHitTesting(false)
        )
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshTasks()
        }
        .onAppear {
            setupNotifications()
            loadInitialData()
            if remindersManager.accessStatus == .denied {
                showReminderSettingsPrompt = true
            }
        }
        .onChange(of: remindersManager.accessStatus) { _, newValue in
            if newValue == .denied {
                showReminderSettingsPrompt = true
            }
        }
        .alert(
            "リマインダーへのアクセスが必要です",
            isPresented: $showReminderSettingsPrompt
        ) {
            Button("設定を開く") { openReminderSettings() }
            Button("後で") { showReminderSettingsPrompt = false }
        } message: {
            Text("タスク一覧を取得するには、システム設定 › プライバシーとセキュリティ › リマインダー で本アプリを許可してください。")
        }
        .alert(
            "カメラへのアクセスが必要です",
            isPresented: $showCameraSettingsPrompt
        ) {
            Button("設定を開く") { openCameraSettings() }
            Button("後で") { showCameraSettingsPrompt = false }
        } message: {
            Text("顔認識による在席検知を行うには、システム設定 › プライバシーとセキュリティ › カメラ で本アプリを許可してください。")
        }
        .overlay(deleteAlertOverlay)
        .overlay(startAlertOverlay)
        .overlay(reminderErrorOverlay)
    }
    
    private var headerSection: some View {
        VStack(alignment: .leading) {
            Text("リスト選択")
                .font(.headline)
                .foregroundColor(colorScheme == .dark ?
                    Color(red: 255/255, green: 224/255, blue: 153/255) :
                    Color(red: 92/255, green: 64/255, blue: 51/255))

            listPickerView
        }
    }
    
    private var listPickerView: some View {
        Picker("リスト", selection: Binding(
            get: { remindersManager.selectedList },
            set: { remindersManager.selectedList = $0 }
        )) {
            ForEach(remindersManager.taskLists, id: \.self) { listName in
                Text(listName).tag(listName)
            }
        }
        .pickerStyle(MenuPickerStyle())
        .onChange(of: remindersManager.selectedList) { _, newList in
            handleListSelection(newList)
        }
    }
    
    private func handleListSelection(_ newList: String) {
        if let existingSet = selectedTaskIdsByList[newList] {
            selectedTaskIds = existingSet
        } else {
            selectedTaskIds = []
        }
        remindersManager.fetchTasks(for: newList) { newTasks in
            updateDisplayedTasks(newTasks)
        }
    }
    
    private var taskListSection: some View {
        VStack(alignment: .leading) {
            Text("タスク一覧")
                .font(.headline)
                .foregroundColor(colorScheme == .dark ?
                    Color(red: 255/255, green: 224/255, blue: 153/255) :
                    Color(red: 92/255, green: 64/255, blue: 51/255))

            taskScrollView
        }
    }
    
    private var taskScrollView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(hierarchicalTasks) { hierarchicalTask in
                    VStack(alignment: .leading, spacing: 0) {
                        hierarchicalTaskRow(
                            task: hierarchicalTask.task,
                            isParent: hierarchicalTask.isParent,
                            isExpanded: expandedParents.contains(hierarchicalTask.id)
                        )
                        
                        if hierarchicalTask.isParent && expandedParents.contains(hierarchicalTask.id) {
                            ForEach(hierarchicalTask.children) { childTask in
                                hierarchicalTaskRow(
                                    task: childTask,
                                    isParent: false,
                                    isExpanded: false,
                                    isChild: true
                                )
                            }
                        }
                    }
                }
            }
            .animation(.easeInOut(duration: 0.3), value: expandedParents)
            .padding(.horizontal, 8)
        }
        .frame(minHeight: 200)
    }
    
    private func hierarchicalTaskRow(task: TaskItem, isParent: Bool, isExpanded: Bool, isChild: Bool = false) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.1)) {
                pressedTaskId = task.id
            }
            
            toggleSelection(task.id)
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                withAnimation(.easeInOut(duration: 0.1)) {
                    pressedTaskId = nil
                }
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
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
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
                
                Image(systemName: selectedTaskIds.contains(task.id) ? "checkmark.square.fill" : "square")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(selectedTaskIds.contains(task.id) ? .white : .primary, selectedTaskIds.contains(task.id) ? .blue : .clear)
                    .padding(.leading, 8)
                
                VStack(alignment: .leading) {
                    Text(isParent ? String(task.title.dropFirst()) : task.title)
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
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.black.opacity(pressedTaskId == task.id ? 0.1 : 0))
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(pressedTaskId == task.id ? 0.97 : 1.0)
        .brightness(pressedTaskId == task.id ? -0.1 : 0)
        .animation(.easeInOut(duration: 0.1), value: pressedTaskId)
        .background(
            Rectangle()
                .fill(Color.gray.opacity(0.01))
                .onHover { hovering in
                    if hovering && !isParent {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
        )
    }
    
    private func taskRowButton(index: Int, task: TaskItem) -> some View {
        Button(action: {
            toggleSelection(task.id)
        }) {
            HStack {
                if selectedTaskIds.contains(task.id) {
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
            .background(index == currentIndex ? Color.gray.opacity(0.2) : Color.clear)
        }
        .buttonStyle(HoverPressButtonStyle(overrideIsPressed: (index == pressedIndex)))
        .onHover { inside in
            if inside {
                currentIndex = index
            }
        }
        .transition(.slide)
    }
    
    private var addTaskButtonSection: some View {
        VStack {
            HStack {
                Button {
                    openRemindersApp()
                    showSuccessMessage()
                } label: {
                    Label("リマインダーを開く", systemImage: "plus")
                }
                .disabled(false)
                .buttonStyle(FocusableButtonStyle(isFocused: false, isEnabled: true))

                Spacer()
            }

            if showAddTaskSuccess {
                Text("リマインダーアプリを開きました")
                    .transition(.scale)
                    .padding(.vertical, 4)
            }
        }
    }
    
    private func showSuccessMessage() {
        withAnimation {
            showAddTaskSuccess = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            withAnimation {
                showAddTaskSuccess = false
            }
        }
    }
    
    private var actionButtonsSection: some View {
        VStack {
            HStack {
                Button("削除") {
                    showDeleteAlert = true
                    isCancelDefault = true
                }
                .disabled(selectedTaskIds.isEmpty)
                .buttonStyle(FocusableButtonStyle(
                    isFocused: false,
                    isEnabled: !selectedTaskIds.isEmpty
                ))

                Spacer()
                
                Button("開始") {
                    showStartAlert = true
                    isCancelDefaultForStart = true
                }
                .disabled(selectedTaskIds.isEmpty)
                .buttonStyle(FocusableButtonStyle(
                    isFocused: !selectedTaskIds.isEmpty,
                    isEnabled: !selectedTaskIds.isEmpty
                ))
            }

            HStack {
                Spacer()
                Button("戻る") {
                    popupCoordinator.showTaskStartPopup = false
                }
                .disabled(false)
                .buttonStyle(FocusableButtonStyle(isFocused: false, isEnabled: true))
            }
        }
    }
    
    private var deleteAlertOverlay: some View {
        Group {
            if showDeleteAlert {
                ZStack {
                    Color.black.opacity(0.4)
                        .edgesIgnoringSafeArea(.all)
                        .allowsHitTesting(false)

                    VStack(spacing: 20) {
                        Text("確認")
                            .font(.title)
                            .fontWeight(.bold)
                            .foregroundColor(colorScheme == .dark ? .white : .primary)
                        
                        Text("以下のタスクを本当に削除しますか？")
                            .foregroundColor(colorScheme == .dark ?
                                Color(red: 255/255, green: 99/255, blue: 71/255) : .red)
                        
                        deleteTasksListView
                        
                        deleteAlertButtons
                    }
                    .padding(30)
                    .frame(width: 450)
                    .background(Color(NSColor.windowBackgroundColor))
                    .cornerRadius(12)
                }
            }
        }
    }
    
    private var deleteTasksListView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(hierarchicalTasks) { hierarchicalTask in
                    if selectedTaskIds.contains(hierarchicalTask.task.id) {
                        VStack(alignment: .leading, spacing: 2) {
                            if hierarchicalTask.isParent {
                                Text("▼ \(String(hierarchicalTask.task.title.dropFirst()))")
                                    .fontWeight(.semibold)
                                    .foregroundColor(colorScheme == .dark ?
                                        Color(red: 255/255, green: 224/255, blue: 153/255) :
                                        Color(red: 92/255, green: 64/255, blue: 51/255))
                                
                                ForEach(hierarchicalTask.children) { childTask in
                                    if selectedTaskIds.contains(childTask.id) {
                                        Text("　　・\(childTask.title)")
                                            .font(.system(size: 13))
                                            .foregroundColor(colorScheme == .dark ? .white.opacity(0.7) : .secondary)
                                    }
                                }
                            } else {
                                Text("・\(hierarchicalTask.task.title)")
                            }
                        }
                    }
                }
            }
        }
        .frame(maxHeight: 150)
        .padding(.horizontal)
    }
    
    private var deleteAlertButtons: some View {
        HStack {
            Button("キャンセル") {
                showDeleteAlert = false
            }
            .buttonStyle(FocusableButtonStyle(
                isFocused: isCancelDefault,
                isEnabled: true
            ))
            
            Spacer().frame(width: 60)
            
            Button("はい") {
                deleteTasks()
                showDeleteAlert = false
            }
            .buttonStyle(FocusableButtonStyle(
                isFocused: !isCancelDefault,
                isEnabled: true
            ))
        }
    }
    
    private func deleteTasks() {
        for id in selectedTaskIds {
            if let task = displayedTasks.first(where: { $0.id == id }) {
                remindersManager.removeTask(task)
            }
        }
        selectedTaskIds.removeAll()
        refreshTasks()
    }
    
    private var startAlertOverlay: some View {
        Group {
            if showStartAlert {
                ZStack {
                    Color.black.opacity(0.4)
                        .edgesIgnoringSafeArea(.all)
                        .allowsHitTesting(false)

                    VStack(spacing: 20) {
                        Text("確認")
                            .font(.title)
                            .fontWeight(.bold)
                            .foregroundColor(colorScheme == .dark ? .white : .primary)
                        
                        Text("以下のタスクを開始します。よろしいですか？")
                            .foregroundColor(colorScheme == .dark ?
                                Color(red: 255/255, green: 224/255, blue: 153/255) :
                                Color(red: 92/255, green: 64/255, blue: 51/255))
                        
                        startTasksListView
                        
                        startAlertButtons
                    }
                    .padding(30)
                    .frame(width: 450)
                    .background(Color(NSColor.windowBackgroundColor))
                    .cornerRadius(12)
                }
            }
        }
    }
    
    private var startTasksListView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(hierarchicalTasks) { hierarchicalTask in
                    if selectedTaskIds.contains(hierarchicalTask.task.id) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("▼ \(String(hierarchicalTask.task.title.dropFirst()))")
                                    .fontWeight(.semibold)
                                    .foregroundColor(colorScheme == .dark ?
                                        Color(red: 255/255, green: 224/255, blue: 153/255) :
                                        Color(red: 92/255, green: 64/255, blue: 51/255))
                            
                            ForEach(hierarchicalTask.children) { childTask in
                                if selectedTaskIds.contains(childTask.id) {
                                    Text("　　・\(childTask.title)")
                                        .font(.system(size: 13))
                                        .foregroundColor(colorScheme == .dark ? .white.opacity(0.7) : .secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(maxHeight: 150)
        .padding(.horizontal)
    }
    
    private var startAlertButtons: some View {
        HStack {
            Button("キャンセル") {
                showStartAlert = false
            }
            .buttonStyle(FocusableButtonStyle(
                isFocused: isCancelDefaultForStart,
                isEnabled: true
            ))
            
            Spacer().frame(width: 60)
            
            Button("開始") {
                showStartAlert = false
                startTaskAction()
                faceRecognitionManager.startRecognitionSession()
            }
            .buttonStyle(FocusableButtonStyle(
                isFocused: !isCancelDefaultForStart,
                isEnabled: true
            ))
        }
    }
    
    private var reminderErrorOverlay: some View {
        Group {
            if let error = reminderAccessError {
                Text(error)
                    .foregroundColor(.red)
                    .padding()
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(8)
                    .padding(.bottom)
            }
            if remindersManager.accessStatus != .authorized {
                Text(remindersManager.accessStatus.message)
                    .foregroundColor(.red)
                    .padding()
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(8)
                    .padding(.bottom)
            }
        }
    }
    
    private func handleKeyDown(_ event: NSEvent) {
        if showDeleteAlert {
            if event.keyCode == 36 || event.keyCode == 76 {
                showDeleteAlert = false
            }
            return
        }
        if showStartAlert {
            if event.keyCode == 36 || event.keyCode == 76 {
                showStartAlert = false
            }
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
        case 36, 76:
            if !selectedTaskIds.isEmpty {
                showStartAlert = true
                isCancelDefaultForStart = true
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
        if currentIndex < displayedTasks.count - 1 {
            currentIndex += 1
        }
    }
    
    private func toggleCheckAndMoveDown() {
        guard currentIndex < displayedTasks.count else { return }
        let (i, task) = (currentIndex, displayedTasks[currentIndex])
        
        toggleSelection(task.id)
        
        if selectedTaskIds.contains(task.id), i < displayedTasks.count - 1 {
            currentIndex += 1
        }
    }
    
    private func updateDisplayedTasks(_ newTasks: [TaskItem]) {
        let sorted = newTasks.sorted { t1, t2 in
            let d1 = t1.dueDate ?? Date.distantFuture
            let d2 = t2.dueDate ?? Date.distantFuture
            return d1 < d2
        }
        displayedTasks = sorted
        hierarchicalTasks = buildHierarchicalStructure(from: sorted)
        expandedParents = Set(hierarchicalTasks.filter { $0.isParent }.map { $0.id })
        currentIndex = displayedTasks.isEmpty ? 0 : min(currentIndex, displayedTasks.count - 1)
    }
    
    private func buildHierarchicalStructure(from tasks: [TaskItem]) -> [HierarchicalTask] {
        var result: [HierarchicalTask] = []
        var currentParent: HierarchicalTask? = nil
        var childrenBuffer: [TaskItem] = []
        
        for task in tasks {
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
        
        return result
    }
    
    private func startTaskAction() {
        Task {
            await faceRecognitionManager.startCamera()
            await MainActor.run {
                popupCoordinator.showWorkInProgress = true
                appUsageManager.startWork(faceRecognitionManager: faceRecognitionManager)
            }
        }
    }
    
    private func toggleSelection(_ id: String) {
        if let hierarchicalTask = hierarchicalTasks.first(where: { $0.id == id && $0.isParent }) {
            if selectedTaskIds.contains(id) {
                selectedTaskIds.remove(id)
                for child in hierarchicalTask.children {
                    selectedTaskIds.remove(child.id)
                }
            } else {
                selectedTaskIds.insert(id)
                for child in hierarchicalTask.children {
                    selectedTaskIds.insert(child.id)
                }
            }
        } else {
            if selectedTaskIds.contains(id) {
                selectedTaskIds.remove(id)
                
                if let parent = findParentTask(for: id) {
                    let anyChildSelected = parent.children.contains { selectedTaskIds.contains($0.id) }
                    if !anyChildSelected {
                        selectedTaskIds.remove(parent.id)
                    }
                }
            } else {
                selectedTaskIds.insert(id)
                
                if let parent = findParentTask(for: id) {
                    selectedTaskIds.insert(parent.id)
                }
            }
        }
        
        selectedTaskIdsByList[remindersManager.selectedList] = selectedTaskIds
    }

    private func findParentTask(for childId: String) -> HierarchicalTask? {
        return hierarchicalTasks.first { hierarchicalTask in
            hierarchicalTask.isParent && hierarchicalTask.children.contains { $0.id == childId }
        }
    }
    
    private func openRemindersApp() {
        if let remindersURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.reminders") {
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(at: remindersURL, configuration: config) { runningApp, error in
                
            }
        } else {
            if let url = URL(string: "Reminders") {
                NSWorkspace.shared.open(url)
            }
        }
    }
    
    private func setupNotifications() {
        NotificationCenter.default.publisher(for: Notification.Name("ReminderAccessDenied"))
            .sink { _ in
                reminderAccessError = "リマインダーへのアクセスが拒否されています。設定アプリで権限を許可してください。"
            }
            .store(in: &reminderSubscriptions)

        NotificationCenter.default.publisher(for: Notification.Name("NoReminderListsFound"))
            .sink { _ in
                reminderAccessError = "リマインダーリストが見つかりませんでした。リマインダーアプリでリストを作成してください。"
            }
            .store(in: &reminderSubscriptions)
        NotificationCenter.default.publisher(
            for: FaceRecognitionManager.cameraAccessDeniedNotification)
            .sink { _ in
                showCameraSettingsPrompt = true
            }
            .store(in: &reminderSubscriptions)
    }
    
    private func loadInitialData() {
        Task {
            await remindersManager.fetchReminderLists()
            if let firstList = remindersManager.taskLists.first {
                remindersManager.selectedList = firstList
                refreshTasks()
            }
        }
    }
    
    private func refreshTasks() {
        if !remindersManager.selectedList.isEmpty {
            remindersManager.fetchTasks(for: remindersManager.selectedList) { newTasks in
                updateDisplayedTasks(newTasks)
            }
        }
    }
    private func openReminderSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") {
            NSWorkspace.shared.open(url)
        }
    }
    private func openCameraSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct HierarchicalTask: Identifiable {
    let id: String
    let task: TaskItem
    let isParent: Bool
    let children: [TaskItem]
    var isExpanded: Bool = true
}
