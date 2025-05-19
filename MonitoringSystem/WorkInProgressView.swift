import AppKit
import SwiftUI

struct WorkInProgressView: View {
    @Environment(FaceRecognitionManager.self) var faceRecognitionManager
    @Environment(CameraManager.self) var cameraManager
    @Environment(PopupCoordinator.self) var popupCoordinator
    @Environment(RemindersManager.self) var remindersManager
    @Environment(AppUsageManager.self) var appUsageManager
    
    @State private var isCancelDefault: Bool = true
    
    let selectedTaskIds: [String]
        
    init(selectedTaskIds: [String]) {
        self.selectedTaskIds = selectedTaskIds
    }
    
    @State private var expandedTasks: [TaskItem] = []
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
                    
                    if selectedTasks.isEmpty {
                        Text("現在、作業中のタスクはありません。")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(selectedTasks) { task in
                            HStack {
                                Text(task.title)
                                Spacer()
                                if let due = task.dueDate {
                                    Text(due, style: .date)
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                }
                            }
                            .padding(.vertical, 2)
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
            startAttendance()
            cameraManager.startSession()
            updateSelectedTasks()
        }
        .onDisappear {
            endAttendance()
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
    }
    
    private func startAttendance() {
        let log = AttendanceLog(userId: "currentUser",
                                startTime: Date(),
                                endTime: nil)
        Task { await SupabaseManager.shared.sendAttendanceLog(log) }
    }
    
    private func endAttendance() {
        let log = AttendanceLog(userId: "currentUser",
                                startTime: Date(),
                                endTime: Date())
        Task { await SupabaseManager.shared.sendAttendanceLog(log) }
    }
}


