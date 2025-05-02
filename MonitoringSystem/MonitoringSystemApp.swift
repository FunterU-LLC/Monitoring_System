//MonitoringSystemApp.swift
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
    @State private var accessibilityTask: Task<Void, Never>?
    private var popupCoordinator = PopupCoordinator()
    @State private var showAccessibilityPrompt = false
    
    var body: some Scene {
        WindowGroup {
            ContentView(bindableCoordinator: popupCoordinator)
                .environment(faceRecognitionManager)
                .environment(remindersManager)
                .environment(appUsageManager)
                .environment(cameraManager)
                .environment(popupCoordinator)
                .task {
                    await checkAccessibilityLoop()
                }
                .onDisappear {
                    accessibilityTask?.cancel()
                    accessibilityTask = nil
                }
                .modelContainer(SessionDataStore.shared.container)
                .environment(SessionDataStore.shared)
                .alert(
                    "アクセシビリティ権限が必要です",
                    isPresented: $showAccessibilityPrompt
                ) {
                    Button("設定を開く") { openAccessibilitySettings() }
                    Button("後で") { showAccessibilityPrompt = false }
                } message: {
                    Text("キーボード操作や最前面アプリ検知を行うには、システム設定 › プライバシーとセキュリティ › アクセシビリティ で本アプリを許可してください。")
                }
        }
    }
    
    
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
            showAccessibilityPrompt = false
        } else {
            print("アクセシビリティ権限がまだ許可されていません。設定を促します。")
            showAccessibilityPrompt = true
        }
    }
    
    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

