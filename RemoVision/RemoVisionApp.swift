import SwiftUI
import ApplicationServices
import SwiftData
import CloudKit
import Observation


private let usePublicDatabase = true

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
    @Environment(\.colorScheme) var colorScheme
    @AppStorage("userName") private var userName: String = ""
    @State private var inputName: String = ""
    @State private var isRegistering: Bool = false
    @State private var errorMessage: String? = nil
    @State private var showContent = false
    @State private var pulseAnimation = false
    @FocusState private var nameFieldFocused: Bool
    
    @Binding var groupID: String
    @Binding var groupName: String
    var onFinish: () -> Void
    var onCancel: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 255/255, green: 224/255, blue: 153/255).opacity(0.15),
                    Color(red: 255/255, green: 204/255, blue: 102/255).opacity(0.05)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            
            VStack(spacing: 24) {
                VStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 255/255, green: 204/255, blue: 102/255),
                                        Color(red: 255/255, green: 184/255, blue: 77/255)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 70, height: 70)
                            .shadow(color: Color(red: 255/255, green: 204/255, blue: 102/255).opacity(0.3), radius: 15, x: 0, y: 5)
                            .scaleEffect(pulseAnimation ? 1.05 : 1.0)
                            .animation(
                                .easeInOut(duration: 2)
                                .repeatForever(autoreverses: true),
                                value: pulseAnimation
                            )
                        
                        Image(systemName: "person.circle.fill")
                            .font(.system(size: 35))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [.white, .white.opacity(0.9)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    }
                    .scaleEffect(showContent ? 1 : 0.5)
                    .opacity(showContent ? 1 : 0)
                    
                    VStack(spacing: 6) {
                        Text("ユーザーネームを設定")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: colorScheme == .dark ? [
                                        Color(red: 255/255, green: 224/255, blue: 153/255),
                                        Color(red: 255/255, green: 214/255, blue: 143/255)
                                    ] : [
                                        Color(red: 92/255, green: 64/255, blue: 51/255),
                                        Color(red: 92/255, green: 64/255, blue: 51/255).opacity(0.8)
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                        
                        Text("「\(groupName)」に参加します")
                            .font(.system(size: 14))
                            .foregroundColor(colorScheme == .dark ? .white.opacity(0.8) : .secondary)
                    }
                    .opacity(showContent ? 1 : 0)
                    .offset(y: showContent ? 0 : 20)
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    Label("あなたのユーザーネーム", systemImage: "person.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(colorScheme == .dark ?
                            Color(red: 255/255, green: 224/255, blue: 153/255) :
                            Color(red: 92/255, green: 64/255, blue: 51/255))
                    
                    TextField("ユーザーネームを入力", text: $inputName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16))
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.gray.opacity(colorScheme == .dark ? 0.2 : 0.1))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .strokeBorder(
                                            nameFieldFocused ?
                                                Color(red: 255/255, green: 204/255, blue: 102/255).opacity(0.5) :
                                                Color.gray.opacity(colorScheme == .dark ? 0.3 : 0.2),
                                            lineWidth: 1.5
                                        )
                                )
                        )
                        .disabled(isRegistering)
                        .focused($nameFieldFocused)
                        .onSubmit {
                            if !inputName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Task { await registerMember() }
                            }
                        }
                }
                .opacity(showContent ? 1 : 0)
                .offset(y: showContent ? 0 : 30)
                
                if let error = errorMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(colorScheme == .dark ?
                                Color(red: 255/255, green: 99/255, blue: 71/255) : .red)
                        
                        Text(error)
                            .font(.system(size: 13))
                            .foregroundColor(colorScheme == .dark ?
                                Color(red: 255/255, green: 99/255, blue: 71/255) : .red)
                            .lineLimit(2)
                        
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.red.opacity(colorScheme == .dark ? 0.2 : 0.1))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Color.red.opacity(colorScheme == .dark ? 0.4 : 0.3), lineWidth: 1)
                            )
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                
                Spacer()
                
                HStack(spacing: 16) {
                    Button {
                        onCancel()
                    } label: {
                        Text("キャンセル")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(colorScheme == .dark ? .white.opacity(0.8) : .secondary)
                            .frame(minWidth: 100)
                            .padding(.vertical, 12)
                            .background(
                                Capsule()
                                    .fill(Color.gray.opacity(colorScheme == .dark ? 0.2 : 0.1))
                                    .overlay(
                                        Capsule()
                                            .strokeBorder(Color.gray.opacity(colorScheme == .dark ? 0.4 : 0.3), lineWidth: 1)
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(isRegistering)
                    
                    Button {
                        Task { await registerMember() }
                    } label: {
                        ZStack {
                            if isRegistering {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle())
                                        .scaleEffect(0.8)
                                        .colorScheme(.light)
                                    Text("登録中...")
                                        .font(.system(size: 15, weight: .semibold))
                                }
                            } else {
                                Label("参加する", systemImage: "checkmark.circle.fill")
                                    .font(.system(size: 15, weight: .semibold))
                            }
                        }
                        .foregroundColor(Color(red: 92/255, green: 64/255, blue: 51/255))
                        .frame(minWidth: 150)
                        .padding(.vertical, 12)
                        .background(
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: inputName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isRegistering ?
                                            [Color.gray, Color.gray.opacity(0.8)] :
                                            [Color(red: 255/255, green: 204/255, blue: 102/255),
                                             Color(red: 255/255, green: 184/255, blue: 77/255)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .shadow(
                                    color: inputName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isRegistering ?
                                        Color.clear :
                                        Color(red: 255/255, green: 204/255, blue: 102/255).opacity(0.3),
                                    radius: 10,
                                    x: 0,
                                    y: 5
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(inputName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isRegistering)
                }
            }
            .padding(32)
            .frame(width: 450)
        }
        .onAppear {
            inputName = userName
            withAnimation(.spring(response: 0.8, dampingFraction: 0.7)) {
                showContent = true
            }
            pulseAnimation = true
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                nameFieldFocused = true
            }
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
            
            // ここで currentGroupID を設定（重要！）
            UserDefaults.standard.set(groupID, forKey: "currentGroupID")
            UserDefaults.standard.synchronize()
        }
        
        print("\n🚀 === Register Member Debug ===")
        print("📝 Attempting to register:")
        print("  groupID: \(groupID)")
        print("  userName: \(trimmedName)")
        print("  groupName: \(groupName)")
        
        // 現在の状態を確認
        await CloudKitService.shared.debugShareAndZoneInfo()
        
        // 共有の受け入れが完了するまで待機
        print("⏳ Waiting for share acceptance to complete...")
        try? await Task.sleep(nanoseconds: 3_000_000_000) // 3秒待機
        
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
            print("❌ Registration failed: \(error)")
            await MainActor.run {
                errorMessage = "メンバー登録に失敗しました: \(error.localizedDescription)"
                isRegistering = false
                
                // エラー時は currentGroupID をクリア
                UserDefaults.standard.removeObject(forKey: "currentGroupID")
                UserDefaults.standard.synchronize()
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
    @State private var showJoinConfirmationAgain = false
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
            .onChange(of: showJoinConfirmationAgain) { _, shouldShow in
                if shouldShow && !pendingGroupID.isEmpty {
                    showJoinConfirmationAgain = false
                    showJoinConfirmation(
                        groupName: pendingGroupName,
                        ownerName: pendingOwnerName,
                        recordID: pendingGroupID
                    )
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
                } onCancel: {
                    showUserNameSheet = false
                    showJoinConfirmationAgain = true
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
        // CloudKitの共有URLは使用しない
        if usePublicDatabase && url.absoluteString.contains("icloud.com") {
            let alert = NSAlert()
            alert.messageText = "共有方法が変更されました"
            alert.informativeText = "このアプリはCloudKitの共有機能を使用していません。グループIDを直接共有してください。"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        
        // パブリックデータベースモード用のURL処理
        if url.scheme == "monitoringsystem" && url.host == "join" {
            let groupID = url.lastPathComponent
            if !groupID.isEmpty {
                handleGroupJoin(groupID: groupID)
            }
            return
        }
        
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
    
    private func handleGroupJoin(groupID: String) {
        print("🔵 Attempting to join group with ID: \(groupID)")
        
        Task {
            let container = CKContainer.default()
            print("📱 Container ID: \(container.containerIdentifier ?? "unknown")")
            
            // CloudKit環境を確認
            #if DEBUG
            print("🏗️ Build Configuration: DEBUG")
            #else
            print("🏗️ Build Configuration: RELEASE")
            #endif
            
            // TestFlightかどうかを確認
            let isTestFlight = Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
            print("📱 Is TestFlight: \(isTestFlight)")
            
            // アカウント状態確認
            do {
                let status = try await container.accountStatus()
                print("🔐 Account Status: \(status.rawValue)")
                switch status {
                case .available:
                    print("   ✅ iCloud account available")
                case .noAccount:
                    print("   ❌ No iCloud account")
                case .restricted:
                    print("   ⚠️ iCloud restricted")
                case .couldNotDetermine:
                    print("   ⚠️ Could not determine status")
                case .temporarilyUnavailable:
                    print("   ⚠️ Temporarily unavailable")
                @unknown default:
                    print("   ❓ Unknown status")
                }
                
                // ユーザー情報を取得
                let userID = try await container.userRecordID()
                print("👤 User Record ID: \(userID.recordName)")
            } catch {
                print("❌ Account check failed: \(error)")
            }
            
            // テスト: 全Groupレコードを取得
            print("🧪 Testing CloudKit access...")
            let db = CKContainer.default().publicCloudDatabase

            let testQuery = CKQuery(recordType: "Group", predicate: NSPredicate(value: true))

            do {
                var foundRecords: [CKRecord] = []
                
                let testOperation = CKQueryOperation(query: testQuery)
                testOperation.resultsLimit = 10  // ここでresultsLimitを設定
                
                testOperation.recordMatchedBlock = { _, result in
                    if case .success(let record) = result {
                        foundRecords.append(record)
                        print("   Found record: \(record.recordID.recordName)")
                    }
                }
                
                await withCheckedContinuation { continuation in
                    testOperation.queryResultBlock = { result in
                        continuation.resume()
                    }
                    db.add(testOperation)
                }
                
                print("🧪 Total Group records found: \(foundRecords.count)")
                
                if foundRecords.isEmpty {
                    print("⚠️ No Group records found in public database")
                    print("   This suggests different environments or sync issues")
                }
            } catch {
                print("🧪 Test query failed: \(error)")
            }
            
            // 既存のデータをクリア
            await SessionDataStore.shared.wipeAllPersistentData()
            CloudKitService.shared.clearTemporaryStorage()
            
            await MainActor.run {
                GroupInfoStore.shared.groupInfo = nil
                currentGroupID = ""
                UserDefaults.standard.removeObject(forKey: "currentGroupID")
                UserDefaults.standard.removeObject(forKey: "userName")
                UserDefaults.standard.synchronize()
            }
            
            // グループ情報を取得
            do {
                let groupRecordID = CKRecord.ID(recordName: groupID)
                
                print("📱 Fetching from Public Database")
                print("   Record Type: Group")
                print("   Record ID: \(groupRecordID.recordName)")
                
                let groupRecord = try await db.record(for: groupRecordID)
                
                print("✅ Group record found!")
                print("   Group Name: \(groupRecord["groupName"] ?? "nil")")
                print("   Owner Name: \(groupRecord["ownerName"] ?? "nil")")
                
                if let groupName = groupRecord["groupName"] as? String,
                   let ownerName = groupRecord["ownerName"] as? String {
                    
                    await MainActor.run {
                        pendingGroupID = groupID
                        pendingGroupName = groupName
                        pendingOwnerName = ownerName
                        showUserNameSheet = true
                    }
                }
            } catch let error as CKError {
                print("❌ CKError occurred:")
                print("   Code: \(error.code.rawValue)")
                print("   Description: \(error.localizedDescription)")
                
                // CloudKitエラーの詳細
                switch error.code {
                case .unknownItem:
                    print("   ⚠️ Record not found")
                case .networkUnavailable:
                    print("   ⚠️ Network unavailable")
                case .notAuthenticated:
                    print("   ⚠️ Not authenticated to iCloud")
                case .permissionFailure:
                    print("   ⚠️ Permission failure")
                case .serverResponseLost:
                    print("   ⚠️ Server response lost")
                case .assetFileNotFound:
                    print("   ⚠️ Asset file not found")
                default:
                    print("   ⚠️ Other error: \(error.code)")
                }
                
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "グループが見つかりません"
                    alert.informativeText = "指定されたグループIDが無効か、グループが存在しません。\n\nエラー詳細: \(error.localizedDescription)"
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            } catch {
                print("❌ Unknown error: \(error)")
                
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "エラー"
                    alert.informativeText = "予期しないエラーが発生しました: \(error.localizedDescription)"
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }
    }
    
    @MainActor
    private func updateGroupInfoFromShare(metadata: CKShare.Metadata) async {
        do {
            // 共有ゾーンIDを保存（メンバーとして参加していることを示す）
            let shareZoneID = metadata.share.recordID.zoneID
            UserDefaults.standard.set(shareZoneID.zoneName, forKey: "sharedZoneName")
            UserDefaults.standard.set(shareZoneID.ownerName, forKey: "sharedZoneOwner")
            UserDefaults.standard.synchronize()
            
            // 共有データベースから情報を取得
            let sharedDB = CKContainer.default().sharedCloudDatabase
            
            // メタデータから直接情報を取得（可能な場合）
            if let shareTitle = metadata.share[CKShare.SystemFieldKey.title] as? String,
               let shareOwnerName = metadata.share["ownerName"] as? String {
                
                pendingGroupID = shareZoneID.zoneName // ゾーン名をグループIDとして使用
                pendingGroupName = shareTitle
                pendingOwnerName = shareOwnerName
                
                // グループ情報を保存（共有データベースからの取得が失敗した場合のフォールバック）
                GroupInfoStore.shared.groupInfo = GroupInfo(
                    groupName: pendingGroupName,
                    ownerName: pendingOwnerName,
                    recordID: pendingGroupID
                )
                
                showUserNameSheet = true
                return
            }
            
            // フォールバック: rootRecordから情報を取得
            if let rootRecord = metadata.rootRecord {
                if let groupName = rootRecord["groupName"] as? String,
                   let ownerName = rootRecord["ownerName"] as? String {
                    
                    pendingGroupID = rootRecord.recordID.recordName
                    pendingGroupName = groupName
                    pendingOwnerName = ownerName
                    
                    // グループ情報を保存（共有データベースからの取得が失敗した場合のフォールバック）
                    GroupInfoStore.shared.groupInfo = GroupInfo(
                        groupName: pendingGroupName,
                        ownerName: pendingOwnerName,
                        recordID: pendingGroupID
                    )
                    
                    showUserNameSheet = true
                    return
                }
            }
            
            // それでも取得できない場合は、レコードIDから取得を試みる
            guard let rootRecordID = metadata.hierarchicalRootRecordID else {
                let alert = NSAlert()
                alert.messageText = "エラー"
                alert.informativeText = "グループ情報が無効です。"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
                return
            }
            
            // 共有の受け入れ処理が完了するまで少し待機
            try await Task.sleep(nanoseconds: 1_000_000_000) // 1秒待機
            
            // 共有データベースから取得
            let groupRecord = try await sharedDB.record(for: rootRecordID)
            
            if let groupName = groupRecord["groupName"] as? String,
               let ownerName = groupRecord["ownerName"] as? String {
                
                pendingGroupID = shareZoneID.zoneName // ゾーン名をグループIDとして使用
                pendingGroupName = groupName
                pendingOwnerName = ownerName
                
                // グループ情報を保存（共有データベースからの取得が失敗した場合のフォールバック）
                GroupInfoStore.shared.groupInfo = GroupInfo(
                    groupName: pendingGroupName,
                    ownerName: pendingOwnerName,
                    recordID: pendingGroupID
                )
                
                showUserNameSheet = true
            } else {
                throw NSError(domain: "GroupInfo", code: -1,
                             userInfo: [NSLocalizedDescriptionKey: "グループ情報が不完全です"])
            }
        } catch {
            // エラーが発生した場合、シェアの情報から取得を試みる
            if let shareTitle = metadata.share[CKShare.SystemFieldKey.title] as? String {
                let shareOwnerName = metadata.share["ownerName"] as? String ??
                                    metadata.ownerIdentity.nameComponents?.formatted() ??
                                    "不明"
                
                let shareZoneID = metadata.share.recordID.zoneID
                pendingGroupID = shareZoneID.zoneName
                pendingGroupName = shareTitle
                pendingOwnerName = shareOwnerName
                
                // グループ情報を保存（共有データベースからの取得が失敗した場合のフォールバック）
                GroupInfoStore.shared.groupInfo = GroupInfo(
                    groupName: pendingGroupName,
                    ownerName: pendingOwnerName,
                    recordID: pendingGroupID
                )
                
                showUserNameSheet = true
            } else {
                let alert = NSAlert()
                alert.messageText = "エラー"
                alert.informativeText = "グループ情報を取得できませんでした。\n詳細: \(error.localizedDescription)"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
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
