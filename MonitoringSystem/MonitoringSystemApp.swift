import SwiftUI
import ApplicationServices
import SwiftData

@main
struct MonitoringSystemApp: App {
    private var sessionStore = SessionDataStore.shared
    private var faceRecognitionManager = FaceRecognitionManager()
    private var remindersManager = RemindersManager()
    private var appUsageManager = AppUsageManager()
    private let supabaseManager = SupabaseManager.shared
    private var cameraManager = CameraManager()
    
    @State private var accessibilityTask: Task<Void, Never>?     // ← Timer→Task
    
    private var popupCoordinator = PopupCoordinator()
    
    //    init() {
    //        SessionDataStore.shared.resetAllSessions()
    //    }
    
    var body: some Scene {
        WindowGroup {
            ContentView(bindableCoordinator: popupCoordinator)
                .environment(faceRecognitionManager)
                .environment(remindersManager)
                .environment(appUsageManager)
                .environment(cameraManager)
                .environment(popupCoordinator)
                .task {
                    await checkAccessibilityLoop()                // ← 起動時に非同期ループ開始
                }
                .onDisappear {
                    accessibilityTask?.cancel()
                    accessibilityTask = nil
                }
                .modelContainer(SessionDataStore.shared.container)
                .environmentObject(SessionDataStore.shared)
        }
    }
    
    // MARK: - Accessibility 監視
    @MainActor
    private func checkAccessibilityLoop() async {
        accessibilityTask?.cancel()
        accessibilityTask = Task { [self] in
            while !Task.isCancelled {
                checkAccessibility()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }
    
    @MainActor
    private func checkAccessibility() {
        let options: [String: Any] = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ]
        let trusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
        if trusted {
            print("アクセシビリティ権限が許可されています")
        } else {
            print("アクセシビリティ権限がまだ許可されていません。設定を促します。")
        }
    }
}

