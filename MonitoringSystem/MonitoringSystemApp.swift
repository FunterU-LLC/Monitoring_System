import SwiftUI
import ApplicationServices
import SwiftData
import CloudKit

extension CKShare.Metadata: @retroactive Identifiable {
    public var id: CKRecord.ID { share.recordID }
}

struct GroupInfo: Codable {
    let groupName: String
    let ownerName: String
    let recordID: String
}

struct UserNameInputSheet: View {
    @AppStorage("userName") private var userName: String = ""
    @State private var inputName: String = ""
    @State private var isRegistering: Bool = false
    @State private var errorMessage: String? = nil
    
    @Binding var groupID: String
    @Binding var groupName: String
    var onFinish: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("ユーザーネームを入力してください").font(.headline)
            
            Text("GroupID: \(groupID)")
                .font(.caption)
                .foregroundColor(.gray)
            
            TextField("ユーザーネーム", text: $inputName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .disabled(isRegistering)
            
            if let error = errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
            }
            
            Button("決定") {
                Task {
                    await registerMember()
                }
            }
            .disabled(inputName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isRegistering)
            
            if isRegistering {
                ProgressView()
                    .scaleEffect(0.8)
            }
        }
        .padding(32)
        .frame(width: 340)
        .onAppear {
            inputName = userName
        }
    }
    
    private func registerMember() async {
        let trimmedName = inputName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        
        guard !groupID.isEmpty else {
            await MainActor.run {
                errorMessage = "グループIDが無効です"
                isRegistering = false
            }
            return
        }
        
        await MainActor.run {
            isRegistering = true
            errorMessage = nil
        }
        
        do {
            _ = try await CloudKitService.shared.createOrUpdateMember(
                groupID: groupID,
                userName: trimmedName
            )
            
            await MainActor.run {
                userName = trimmedName
                isRegistering = false
                onFinish()
            }
        } catch {
            await MainActor.run {
                errorMessage = "メンバー登録に失敗しました: \(error.localizedDescription)"
                isRegistering = false
            }
        }
    }
}

class GroupInfoStore: ObservableObject {
    private let userDefaultsKey = "GroupInfoStore.groupInfo"
    @Published var groupInfo: GroupInfo? {
        didSet {
            let defaults = UserDefaults.standard
            if let groupInfo = groupInfo {
                if let data = try? JSONEncoder().encode(groupInfo) {
                    defaults.set(data, forKey: userDefaultsKey)
                }
            } else {
                defaults.removeObject(forKey: userDefaultsKey)
            }
        }
    }
    static let shared = GroupInfoStore()

    init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: userDefaultsKey),
           let loaded = try? JSONDecoder().decode(GroupInfo.self, from: data) {
            self.groupInfo = loaded
        } else {
            self.groupInfo = nil
        }
    }
}

@main
struct MonitoringSystemApp: App {
    private var sessionStore = SessionDataStore.shared
    private var faceRecognitionManager = FaceRecognitionManager()
    private var remindersManager = RemindersManager()
    private var appUsageManager = AppUsageManager()
    private var cameraManager = CameraManager()
    @State private var accessibilityTask: Task<Void, Never>?
    private var popupCoordinator = PopupCoordinator()
    @State private var showAccessibilityPrompt = false
    
    @AppStorage("currentGroupID") private var currentGroupID: String = ""
    
    @State private var pendingShareMetadata: CKShare.Metadata? = nil
    
    @State private var showUserNameSheet = false
    @State private var pendingGroupID: String = ""
    @State private var pendingGroupName: String = ""
    @State private var pendingOwnerName: String = ""

    var body: some Scene {
        WindowGroup {
            Group {
                if currentGroupID.isEmpty {
                    OnboardingView()
                        .environment(faceRecognitionManager)
                        .environment(remindersManager)
                        .environment(appUsageManager)
                        .environment(cameraManager)
                        .environment(popupCoordinator)
                } else {
                    ContentView(bindableCoordinator: popupCoordinator)
                        .environment(faceRecognitionManager)
                        .environment(remindersManager)
                        .environment(appUsageManager)
                        .environment(cameraManager)
                        .environment(popupCoordinator)
                }
            }
            .onOpenURL { url in
                handleIncomingURL(url)
            }
            .sheet(item: $pendingShare, onDismiss: {
                pendingShare = nil
            }) { md in
                VStack {
                    AcceptShareSheet(metadata: md) { joined in
                        if joined {
                            currentGroupID = md.share.recordID.recordName
                        } else {
                        }
                        pendingShare = nil
                    }
                    .onAppear {
                    }
                }
                .frame(width: 500, height: 300)
            }
            .sheet(isPresented: $showUserNameSheet) {
                UserNameInputSheet(
                    groupID: $pendingGroupID,
                    groupName: $pendingGroupName
                ) {
                    if !pendingGroupID.isEmpty {
                        GroupInfoStore.shared.groupInfo = GroupInfo(
                            groupName: pendingGroupName,
                            ownerName: pendingOwnerName,
                            recordID: pendingGroupID
                        )
                        currentGroupID = pendingGroupID
                    }
                    pendingGroupID = ""
                    pendingGroupName = ""
                    pendingOwnerName = ""
                    showUserNameSheet = false
                }
            }
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
    
    @State private var pendingShare: CKShare.Metadata? = nil
    
    private func handleIncomingURL(_ url: URL) {
        
        if url.scheme == "monitoringsystem" && url.host == "share" {
            
            let recordID = url.lastPathComponent
            if !recordID.isEmpty {
                
                fetchGroupRecordDirectly(recordID: recordID)
            } else {
            }
            return
        }
        
        if url.absoluteString.contains("www.icloud.com") && url.absoluteString.contains("/share/") {
            
            let op = CKFetchShareMetadataOperation(shareURLs: [url])
            op.perShareMetadataResultBlock = { _, result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let md):
                        self.pendingShare = md
                    case .failure:
                        if let shareURL = url.absoluteString.components(separatedBy: "/share/").last {
                            self.currentGroupID = shareURL
                        }
                    }
                }
            }
            CKContainer.default().add(op)
            
            op.perShareMetadataResultBlock = { _, result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let md):
                        self.pendingShare = md
                    case .failure:
                        if let shareURL = url.absoluteString.components(separatedBy: "/share/").last {
                            self.currentGroupID = shareURL
                        }
                    }
                }
            }
            CKContainer.default().add(op)
        } else {
        }
    }

    private func fetchGroupRecordDirectly(recordID: String) {
        
        let zoneID = CloudKitService.workZoneID
        let groupRecordID = CKRecord.ID(recordName: recordID, zoneID: zoneID)
        
        let db = CKContainer.default().privateCloudDatabase
        
        db.fetch(withRecordID: groupRecordID) { record, error in
            DispatchQueue.main.async {
                if error != nil {
                    self.currentGroupID = recordID
                } else if let record = record {
                    
                    let groupName = record["groupName"] as? String ?? "Unknown Group"
                    let ownerName = record["ownerName"] as? String ?? "Unknown Owner"
                    
                    self.showJoinConfirmation(groupName: groupName, ownerName: ownerName, recordID: recordID)
                } else {
                    self.currentGroupID = recordID
                }
            }
        }
    }
    
    private func showJoinConfirmation(groupName: String, ownerName: String, recordID: String) {
        
        let alert = NSAlert()
        alert.messageText = "グループへの参加"
        alert.informativeText = "グループ名: \(groupName)\nオーナー: \(ownerName)\n\nこのグループに参加しますか？"
        alert.addButton(withTitle: "参加")
        alert.addButton(withTitle: "キャンセル")
        
        let joinButton = alert.buttons[0]
        joinButton.hasDestructiveAction = false
        joinButton.keyEquivalent = "\r"
        
        let cancelButton = alert.buttons[1]
        cancelButton.keyEquivalent = "\u{1b}"
        
        let response = alert.runModal()
        
        if response == .alertFirstButtonReturn {
            Task { @MainActor in
                self.pendingGroupID = recordID
                self.pendingGroupName = groupName
                self.pendingOwnerName = ownerName
                self.showUserNameSheet = true
            }
        }
    }


    private func fetchShareMetadataDirectly(recordID: String, setDirectGroupIDOnFailure: Bool = false) {
        
        if let shareURL = URL(string: "https://www.icloud.com/share/\(recordID)") {
            
            let op = CKFetchShareMetadataOperation(shareURLs: [shareURL])
            op.perShareMetadataResultBlock = { _, result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let md):
                        self.pendingShare = md
                    case .failure:
                        if setDirectGroupIDOnFailure {
                            self.currentGroupID = recordID
                        }
                    }
                }
            }
            CKContainer.default().add(op)
        } else {
            if setDirectGroupIDOnFailure {
                DispatchQueue.main.async {
                    self.currentGroupID = recordID
                }
            } else {
            }
        }
    }

    private func fallbackDirectlyToGroupID(_ recordID: String) {
        DispatchQueue.main.async {
            self.currentGroupID = recordID
            self.pendingShare = nil
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
            showAccessibilityPrompt = false
        } else {
            showAccessibilityPrompt = true
        }
    }
    
    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
