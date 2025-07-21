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
    var pendingURL: URL?          // 受け取った URL を保持
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
        
        #if DEBUG
        print("===== GroupInfoStore Init =====")
        if let data = defaults.data(forKey: userDefaultsKey) {
            print("UserDefaultsにデータあり: \(data.count) bytes")
            do {
                let loaded = try JSONDecoder().decode(GroupInfo.self, from: data)
                print("デコード成功: \(loaded.groupName)")
                self.groupInfo = loaded
            } catch {
                print("❌ デコードエラー: \(error)")
                self.groupInfo = nil
            }
        } else {
            print("UserDefaultsにデータなし")
            self.groupInfo = nil
        }
        print("================================")
        #endif
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
            .environment(popupCoordinator)
            .environment(faceRecognitionManager)
            .environment(remindersManager)
            .environment(appUsageManager)
            .environment(cameraManager)
            .environment(deepLink)  // 共有
            // ❷ URL 変化を検知して処理
            .onChange(of: deepLink.pendingURL) { _, url in
                if let url {
                    handleIncomingURL(url)
                    deepLink.pendingURL = nil          // 消費したらクリア
                }
            }
            // ❸ cold-launch 直後に URL がすでに入っている場合のフォロー
            .task {
                if let url = deepLink.pendingURL {
                    handleIncomingURL(url)
                    deepLink.pendingURL = nil
                }
            }
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                if let url = activity.webpageURL {
                    handleIncomingURL(url)   // 既存メソッドを再利用
                }
            }
            .onOpenURL { url in
                #if DEBUG
                print("🔴🔴🔴 onOpenURL called 🔴🔴🔴")
                print("URL: \(url.absoluteString)")
                #endif
                
                handleIncomingURL(url)
            }
            // 既存のコードを置き換え
            .sheet(item: $pendingShareMetadata, onDismiss: {
                pendingShareMetadata = nil
            }) { metadata in
                VStack {
                    AcceptShareSheet(metadata: metadata) { joined in
                        if joined {
                            // 参加成功時の処理
                            Task {
                                // グループ情報を取得して保存
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
                #if DEBUG
                print("🔴 SwiftUI onOpenURL: \(url)")
                #endif
                handleIncomingURL(url)
            }
            .onReceive(NotificationCenter.default.publisher(
                for: Notification.Name("RemoVisionHandleURL")
            )) { notification in
                #if DEBUG
                print("🟢 Notification受信")
                #endif
                
                if let url = notification.userInfo?["url"] as? URL {
                    handleIncomingURL(url)
                }
            }
            .onReceive(NotificationCenter.default.publisher(
                for: Notification.Name("TestCKShareURL")
            )) { notification in
                if let url = notification.userInfo?["url"] as? URL {
                    #if DEBUG
                    print("🟨 Test URL受信: \(url)")
                    #endif
                    handleIncomingURL(url)
                }
            }
        }
    }
    
    private func handleIncomingURL(_ url: URL) {
        #if DEBUG
        print("🟢🟢🟢 handleIncomingURL START 🟢🟢🟢")
        print("===== handleIncomingURL =====")
        print("受信URL: \(url.absoluteString)")
        print("スキーム: \(url.scheme ?? "nil")")
        print("ホスト: \(url.host ?? "nil")")
        print("パス: \(url.path)")
        #endif
        
        // iCloud共有URLの処理（CKShare）
        if url.absoluteString.contains("icloud.com") &&
           (url.absoluteString.contains("/share/") || url.absoluteString.contains("ckshare")) {
            
            #if DEBUG
            print("📥 CKShare URLを検出")
            #endif
            
            // デバッグボタンと同じ処理を実行
            Task {
                // 現在のグループから退出
                await SessionDataStore.shared.wipeAllPersistentData()
                CloudKitService.shared.clearTemporaryStorage()
                
                await MainActor.run {
                    GroupInfoStore.shared.groupInfo = nil
                    currentGroupID = ""
                    // userNameはAppStorageなので自動的に更新される
                    UserDefaults.standard.removeObject(forKey: "currentGroupID")
                    UserDefaults.standard.removeObject(forKey: "userName")
                    UserDefaults.standard.synchronize()
                    
                    // 少し待ってから共有メタデータを取得
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        let op = CKFetchShareMetadataOperation(shareURLs: [url])
                        
                        op.perShareMetadataResultBlock = { shareURL, result in
                            DispatchQueue.main.async {
                                switch result {
                                case .success(let metadata):
                                    #if DEBUG
                                    print("✅ 共有メタデータ取得成功")
                                    print("Share record ID: \(metadata.share.recordID)")
                                    print("Root record ID: \(metadata.rootRecordID)")
                                    #endif
                                    
                                    // AcceptShareSheetを表示
                                    self.pendingShareMetadata = metadata
                                    
                                case .failure(let error):
                                    #if DEBUG
                                    print("❌ 共有メタデータ取得失敗: \(error)")
                                    #endif
                                    
                                    // エラーアラートを表示
                                    let alert = NSAlert()
                                    alert.messageText = "共有URLエラー"
                                    alert.informativeText = "共有情報を取得できませんでした。\n\(error.localizedDescription)"
                                    alert.alertStyle = .warning
                                    alert.addButton(withTitle: "OK")
                                    alert.runModal()
                                }
                            }
                        }
                        
                        op.fetchShareMetadataResultBlock = { result in
                            switch result {
                            case .success:
                                #if DEBUG
                                print("✅ 共有メタデータ操作完了")
                                #endif
                            case .failure(let error):
                                #if DEBUG
                                print("❌ 共有メタデータ操作エラー: \(error)")
                                #endif
                            }
                        }
                        
                        CKContainer.default().add(op)
                    }
                }
            }
            return
        }
        
        // カスタムURLスキームの処理（フォールバック）
        if url.scheme == "monitoringsystem" && url.host == "share" {
            #if DEBUG
            print("📥 カスタムURLスキームを検出")
            #endif
            
            let recordID = url.lastPathComponent
            if !recordID.isEmpty {
                fetchGroupRecordDirectly(recordID: recordID)
            } else {
                #if DEBUG
                print("❌ レコードIDが空です")
                #endif
            }
            return
        }
        
        #if DEBUG
        print("⚠️ 未対応のURL形式")
        #endif
    }
    
    @MainActor
    private func updateGroupInfoFromShare(metadata: CKShare.Metadata) async {
        do {
            // 共有を承認済みの場合、ルートレコードを取得
            let db = CKContainer.default().privateCloudDatabase
            let groupRecord = try await db.record(for: metadata.rootRecordID)
            
            if let groupName = groupRecord["groupName"] as? String,
               let ownerName = groupRecord["ownerName"] as? String {
                
                #if DEBUG
                print("✅ 共有グループ情報取得成功")
                print("グループ名: \(groupName)")
                print("オーナー: \(ownerName)")
                #endif
                
                // ユーザー名入力画面を表示
                pendingGroupID = metadata.rootRecordID.recordName
                pendingGroupName = groupName
                pendingOwnerName = ownerName
                showUserNameSheet = true
            }
        } catch {
            #if DEBUG
            print("❌ グループ情報取得エラー: \(error)")
            #endif
            
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

// ファイルの最後のAppDelegateを以下に置き換え
class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate?
    
    override init() {
        super.init()
        AppDelegate.shared = self
    }
    
    func applicationWillFinishLaunching(_ notification: Notification) {
        // URLイベントハンドラーを登録
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:replyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
        
        #if DEBUG
        print("🟦 URLハンドラー登録完了")
        #endif
    }
    
    @objc func handleGetURL(_ event: NSAppleEventDescriptor, replyEvent: NSAppleEventDescriptor) {
        if let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
           let url = URL(string: urlString) {

            // ❶ 直接状態にセット（通知は不要になる）
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

        #if DEBUG
        print("💌 userDidAcceptCloudKitShareWith: \(metadata)")
        #endif

        // ❶: Sheet を出すために Notification を投げる
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
