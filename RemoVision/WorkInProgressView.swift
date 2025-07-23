import AppKit
import SwiftUI

struct WorkInProgressView: View {
    @Environment(FaceRecognitionManager.self) var faceRecognitionManager
    @Environment(CameraManager.self) var cameraManager
    @Environment(PopupCoordinator.self) var popupCoordinator
    @Environment(RemindersManager.self) var remindersManager
    @Environment(AppUsageManager.self) var appUsageManager
    
    @State private var isCancelDefault: Bool = true
    @State private var hierarchicalTasks: [HierarchicalTask] = []
    
    let selectedTaskIds: [String]
        
    init(selectedTaskIds: [String]) {
        self.selectedTaskIds = selectedTaskIds
    }
    
    @State private var selectedTasks: [TaskItem] = []
    
    @State private var showBackAlert: Bool = false
    
    @State private var isFinishButtonFocused: Bool = true

    var body: some View {
        VStack {
            Text("作業中")
                .font(.largeTitle)
                .padding(.top, 16)
            
            if faceRecognitionManager.isFaceDetected {
                Text("顔を認識しています")
                    .foregroundColor(.green)
            } else {
                Text("顔が認識されていません")
                    .foregroundColor(.red)
            }
            
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("作業中のタスク")
                        .font(.headline)
                    
                    if hierarchicalTasks.isEmpty {
                        Text("現在、作業中のタスクはありません。")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(hierarchicalTasks) { hierarchicalTask in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text("▼ \(String(hierarchicalTask.task.title.dropFirst()))")
                                        .fontWeight(.semibold)
                                        .foregroundColor(Color(red: 92/255, green: 64/255, blue: 51/255))
                                    
                                    Spacer()
                                    
                                    if let due = hierarchicalTask.task.dueDate {
                                        Text(due, style: .date)
                                            .font(.caption)
                                            .foregroundColor(.gray)
                                    }
                                }
                                .padding(.vertical, 2)
                                
                                ForEach(hierarchicalTask.children) { childTask in
                                    HStack {
                                        Text("　　・\(childTask.title)")
                                            .font(.system(size: 13))
                                            .foregroundColor(.secondary)
                                        
                                        Spacer()
                                        
                                        if let due = childTask.dueDate {
                                            Text(due, style: .date)
                                                .font(.caption2)
                                                .foregroundColor(.gray)
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal)
            }
            .frame(maxHeight: 300)
            
            Button("タスク選択に戻る") {
                showBackAlert = true
            }
            
            Spacer()
            
            Button("作業を終了する") {
                popupCoordinator.showFinishPopup = true
            }
            .font(.title)
            .padding()
            .buttonStyle(FocusableButtonStyle(
                isFocused: isFinishButtonFocused,
                isEnabled: true
            ))

        }
        .frame(minWidth: 500, minHeight: 400)
        .sheet(isPresented: Binding(
            get: { popupCoordinator.showFinishPopup },
            set: { popupCoordinator.showFinishPopup = $0 }
        )) {
            FinishTaskPopupView(selectedTaskIds: selectedTaskIds)
                .environment(remindersManager)
                .environment(appUsageManager)
                .environment(popupCoordinator)
                .environment(faceRecognitionManager)
        }
        .onAppear {
            cameraManager.startSession()
            updateSelectedTasks()
        }
        .onDisappear {
            cameraManager.stopSession()
        }
        .overlay(
            Group {
                if showBackAlert {
                    Color.black.opacity(0.4)
                        .edgesIgnoringSafeArea(.all)
                    VStack(spacing: 20) {
                        Text("注意")
                            .font(.title)
                            .fontWeight(.bold)
                        Text("作業時間が破棄されます。よろしいですか。")
                            .foregroundColor(.red)

                        HStack {
                            Button("キャンセル") {
                                showBackAlert = false
                            }
                            .buttonStyle(FocusableButtonStyle(
                                isFocused: isCancelDefault,
                                isEnabled: true
                            ))

                            Spacer().frame(width: 40)
                            Button("はい") {
                                showBackAlert = false
                                faceRecognitionManager.stopCamera()
                                appUsageManager.stopWork()
                                popupCoordinator.showWorkInProgress = false
                            }
                            .buttonStyle(FocusableButtonStyle(
                                isFocused: !isCancelDefault,
                                isEnabled: true
                            ))
                        }
                    }
                    .padding(30)
                    .frame(minWidth: 400, minHeight: 200)
                    .background(Color(NSColor.windowBackgroundColor))
                    .cornerRadius(12)
                }
            },
            alignment: .center
        )
        .overlay(
            KeyboardMonitorView { event in
                if event.keyCode == 36 || event.keyCode == 76 {
                    if showBackAlert {
                        showBackAlert = false
                        return
                    }
                    popupCoordinator.showFinishPopup = true
                }
            }
            .allowsHitTesting(false),
            alignment: .center
        )
    }

    private func updateSelectedTasks() {
        selectedTasks = remindersManager.tasks.filter { selectedTaskIds.contains($0.id) }
        buildHierarchicalStructure()
    }
    
    private func buildHierarchicalStructure() {
        var result: [HierarchicalTask] = []
        var currentParent: HierarchicalTask? = nil
        var childrenBuffer: [TaskItem] = []
        
        for task in selectedTasks {
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
    }
}
