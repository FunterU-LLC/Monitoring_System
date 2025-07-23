import SwiftUI
import ApplicationServices
import SwiftData
import CloudKit
import Observation


extension CKShare.Metadata: @retroactive Identifiable {
    public var id: CKRecord.ID { share.recordID }
}

@Observable
final class DeepLinkManager {
    static let shared = DeepLinkManager()
    var pendingURL: URL?
    private init() {}
}

struct GroupInfo: Codable, Equatable {
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
        
        if let data = defaults.data(forKey: userDefaultsKey) {
            do {
                let loaded = try JSONDecoder().decode(GroupInfo.self, from: data)
                self.groupInfo = loaded
            } catch {
                self.groupInfo = nil
            }
        } else {
            self.groupInfo = nil
        }
    }
}

@main
struct RemoVisionApp: App {
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
    @State private var permissionCoordinator = PermissionCoordinator()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var deepLink = DeepLinkManager.shared

    var body: some Scene {
        WindowGroup {
            Group {
                if !permissionCoordinator.allGranted {
                    PermissionGateView()
                        .environment(permissionCoordinator)
                        .task { await permissionCoordinator.requestInitialPermissions() }

                } else if currentGroupID.isEmpty {
                    OnboardingView()
                        .environment(permissionCoordinator)

                } else {
                    ContentView(bindableCoordinator: popupCoordinator)
                        .environment(permissionCoordinator)
                }
            }
            .frame(minWidth: 800, minHeight: 600)
            .overlay(WindowMinSizeEnforcer(minWidth: 800, minHeight: 600)
                        .allowsHitTesting(false))
            .environment(popupCoordinator)
            .environment(faceRecognitionManager)
            .environment(remindersManager)
            .environment(appUsageManager)
            .environment(cameraManager)
            .environment(deepLink)
            .onChange(of: deepLink.pendingURL) { _, url in
                if let url {
                    handleIncomingURL(url)
                    deepLink.pendingURL = nil
                }
            }
            .task {
                if let url = deepLink.pendingURL {
                    handleIncomingURL(url)
                    deepLink.pendingURL = nil
                }
            }
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                if let url = activity.webpageURL {
                    handleIncomingURL(url)
                }
            }
            .onOpenURL { url in
                handleIncomingURL(url)
            }
            .sheet(item: $pendingShareMetadata, onDismiss: {
                pendingShareMetadata = nil
            }) { metadata in
                VStack {
                    AcceptShareSheet(metadata: metadata) { joined in
                        if joined {
                            Task {
                                await updateGroupInfoFromShare(metadata: metadata)
                            }
                        }
                        pendingShareMetadata = nil
                    }
                }
                .frame(width: 500, height: 300)
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: .RemoVisionDidReceiveShareMetadata)
            ) { note in
                if let md = note.userInfo?["metadata"] as? CKShare.Metadata {
                    pendingShareMetadata = md
                }
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
            .onOpenURL { url in
                handleIncomingURL(url)
            }
            .onReceive(NotificationCenter.default.publisher(
                for: Notification.Name("RemoVisionHandleURL")
            )) { notification in
                if let url = notification.userInfo?["url"] as? URL {
                    handleIncomingURL(url)
                }
            }
            .onReceive(NotificationCenter.default.publisher(
                for: Notification.Name("TestCKShareURL")
            )) { notification in
                if let url = notification.userInfo?["url"] as? URL {
                    handleIncomingURL(url)
                }
            }
        }
    }
    
    private func handleIncomingURL(_ url: URL) {
        if url.absoluteString.contains("icloud.com") &&
           (url.absoluteString.contains("/share/") || url.absoluteString.contains("ckshare")) {

            Task {
                await SessionDataStore.shared.wipeAllPersistentData()
                CloudKitService.shared.clearTemporaryStorage()
                
                await MainActor.run {
                    GroupInfoStore.shared.groupInfo = nil
                    currentGroupID = ""
                    UserDefaults.standard.removeObject(forKey: "currentGroupID")
                    UserDefaults.standard.removeObject(forKey: "userName")
                    UserDefaults.standard.synchronize()
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        let op = CKFetchShareMetadataOperation(shareURLs: [url])
                        
                        op.perShareMetadataResultBlock = { shareURL, result in
                            DispatchQueue.main.async {
                                switch result {
                                case .success(let metadata):
                                    self.pendingShareMetadata = metadata
                                    
                                case .failure(let error):
                                    let alert = NSAlert()
                                    alert.messageText = "共有URLエラー"
                                    alert.informativeText = "共有情報を取得できませんでした。\n\(error.localizedDescription)"
                                    alert.alertStyle = .warning
                                    alert.addButton(withTitle: "OK")
                                    alert.runModal()
                                }
                            }
                        }
                        CKContainer.default().add(op)
                    }
                }
            }
            return
        }
        
        if url.scheme == "monitoringsystem" && url.host == "share" {
            let recordID = url.lastPathComponent
            if !recordID.isEmpty {
                fetchGroupRecordDirectly(recordID: recordID)
            }
            return
        }
    }
    
    @MainActor
    private func updateGroupInfoFromShare(metadata: CKShare.Metadata) async {
        do {
            let db = CKContainer.default().privateCloudDatabase
            let groupRecord = try await db.record(for: metadata.rootRecordID)
            
            if let groupName = groupRecord["groupName"] as? String,
               let ownerName = groupRecord["ownerName"] as? String {
                
                pendingGroupID = metadata.rootRecordID.recordName
                pendingGroupName = groupName
                pendingOwnerName = ownerName
                showUserNameSheet = true
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "エラー"
            alert.informativeText = "グループ情報を取得できませんでした。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
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

class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate?
    
    override init() {
        super.init()
        AppDelegate.shared = self
    }
    
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:replyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }
    
    @objc func handleGetURL(_ event: NSAppleEventDescriptor, replyEvent: NSAppleEventDescriptor) {
        if let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
           let url = URL(string: urlString) {

            DispatchQueue.main.async {
                DeepLinkManager.shared.pendingURL = url
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        DispatchQueue.main.async {
            DeepLinkManager.shared.pendingURL = urls.first
        }
    }

    func application(_ application: NSApplication,
                     userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        NotificationCenter.default.post(
            name: .RemoVisionDidReceiveShareMetadata,
            object: nil,
            userInfo: ["metadata": metadata]
        )
    }
}

extension Notification.Name {
    static let RemoVisionDidReceiveShareMetadata =
        Notification.Name("RemoVisionDidReceiveShareMetadata")
}
