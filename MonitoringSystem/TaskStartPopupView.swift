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

            taskScrollView
        }
    }
    
    private var taskScrollView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(displayedTasks.enumerated()), id: \.element.id) { i, task in
                    taskRowButton(index: i, task: task)
                    
                    Divider()
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeInOut, value: displayedTasks.map(\.id))
            .padding(.horizontal, 8)
        }
        .frame(minHeight: 200)
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
                        
                        Text("以下のタスクを本当に削除しますか？")
                            .foregroundColor(.red)
                        
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
                ForEach(selectedTaskIds.sorted(), id: \.self) { tid in
                    if let t = displayedTasks.first(where: { $0.id == tid }) {
                        Text("・\(t.title)")
                    }
                }
            }
        }
        .frame(maxHeight: 100)
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
                        
                        Text("以下のタスクを開始します。よろしいですか？")
                            .foregroundColor(.red)
                        
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
                ForEach(selectedTaskIds.sorted(), id: \.self) { tid in
                    if let t = displayedTasks.first(where: { $0.id == tid }) {
                        Text("・\(t.title)")
                    }
                }
            }
        }
        .frame(maxHeight: 100)
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
        currentIndex = displayedTasks.isEmpty ? 0 : min(currentIndex, displayedTasks.count - 1)
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
        if selectedTaskIds.contains(id) {
            selectedTaskIds.remove(id)
        } else {
            selectedTaskIds.insert(id)
        }
        selectedTaskIdsByList[remindersManager.selectedList] = selectedTaskIds
    }
    
    private func openRemindersApp() {
        if let remindersURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.reminders") {
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(at: remindersURL, configuration: config) { runningApp, error in
                if let error = error {
                    print("Failed to open Reminders app: \(error)")
                } else {
                    print("Reminders app opened successfully.")
                }
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

