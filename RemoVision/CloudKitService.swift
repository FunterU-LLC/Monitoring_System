import Foundation
import CloudKit
import SwiftData
import Network

@MainActor
final class CloudKitService {
    
    @Published var lastError: String? = nil
    
    private let usePublicDatabase = true

    static let shared = CloudKitService()
    static let workZoneID = CKRecordZone.ID(zoneName: "WorkGroupZone", ownerName: CKCurrentUserDefaultName)
    
    private let networkMonitor = NWPathMonitor()
    private let networkQueue = DispatchQueue(label: "NetworkMonitor")
    @Published var isOnline: Bool = false
    
    private let tempDataURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("MonitoringSystem/temp_sessions.json")
    }()
    
    private var pendingUploads: [OfflineSessionData] = []
    
    init() {
        setupNetworkMonitoring()
        loadPendingUploads()
    }
    
    deinit {
        networkMonitor.cancel()
    }
    
    private var isUsingSharedZone: Bool {
        // currentGroupIDまたは共有ゾーン情報があればtrue
        let hasGroupID = !(UserDefaults.standard.string(forKey: "currentGroupID") ?? "").isEmpty
        let hasSharedZone = UserDefaults.standard.string(forKey: "sharedZoneName") != nil
        return hasGroupID || hasSharedZone
    }

    private var currentZoneID: CKRecordZone.ID {
        // パブリックデータベースモードの場合はデフォルトゾーンを使用
        if usePublicDatabase {
            return CKRecordZone.default().zoneID
        }
        
        // 従来の実装
        if let zoneName = UserDefaults.standard.string(forKey: "sharedZoneName"),
           let ownerName = UserDefaults.standard.string(forKey: "sharedZoneOwner") {
            return CKRecordZone.ID(zoneName: zoneName, ownerName: ownerName)
        }
        
        if let groupID = UserDefaults.standard.string(forKey: "currentGroupID"), !groupID.isEmpty {
            return CKRecordZone.ID(zoneName: groupID, ownerName: CKCurrentUserDefaultName)
        }
        
        return Self.workZoneID
    }

    private var currentDatabase: CKDatabase {
        // パブリックデータベースモードの場合
        if usePublicDatabase {
            return CKContainer.default().publicCloudDatabase
        }
        
        // 従来の実装（互換性のため残す）
        if UserDefaults.standard.string(forKey: "sharedZoneName") != nil ||
           UserDefaults.standard.string(forKey: "sharedZoneOwner") != nil {
            return CKContainer.default().sharedCloudDatabase
        } else {
            return CKContainer.default().privateCloudDatabase
        }
    }
    
    private func setupNetworkMonitoring() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self = self else { return }
                
                let wasOffline = !self.isOnline
                self.isOnline = path.status == .satisfied
                
                if wasOffline && self.isOnline {
                    await self.uploadPendingData()
                }
            }
        }
        networkMonitor.start(queue: networkQueue)
    }

    struct OfflineSessionData: Codable {
        let id: UUID
        let groupID: String
        let userName: String
        let sessionData: PortableSessionRecord
        let timestamp: Date
        
        init(groupID: String, userName: String, sessionData: PortableSessionRecord) {
            self.id = UUID()
            self.groupID = groupID
            self.userName = userName
            self.sessionData = sessionData
            self.timestamp = Date()
        }
    }
    
    struct PortableSessionRecord: Codable {
        let endTime: Date
        let completedCount: Int
        let taskSummaries: [PortableTaskUsageSummary]
    }
    
    struct PortableTaskUsageSummary: Codable {
        let reminderId: String
        let taskName: String
        let isCompleted: Bool
        let startTime: Date
        let endTime: Date
        let totalSeconds: Double
        let comment: String?
        let appBreakdown: [PortableAppUsage]
        let parentTaskName: String?
    }
    
    struct PortableAppUsage: Codable {
        let name: String
        let seconds: Double
    }

    private func ensureZone() async throws {
        // パブリックデータベースモードの場合、ゾーン作成は不要
        if usePublicDatabase {
            return
        }
        
        // 既存の実装をそのまま維持
        if isUsingSharedZone {
            return
        }
        
        let db = CKContainer.default().privateCloudDatabase

        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                db.fetch(withRecordZoneID: Self.workZoneID) { _, error in
                    if let error = error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume(returning: ())
                    }
                }
            }
        } catch {
            if (error as? CKError)?.code == .zoneNotFound {
                let zone = CKRecordZone(zoneID: Self.workZoneID)
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    let op = CKModifyRecordZonesOperation(recordZonesToSave: [zone],
                                                          recordZoneIDsToDelete: nil)
                    op.modifyRecordZonesResultBlock = { result in
                        switch result {
                        case .success:
                            cont.resume(returning: ())
                        case .failure(let err):
                            cont.resume(throwing: err)
                        }
                    }
                    db.add(op)
                }
            } else {
                throw error
            }
        }
    }

    enum CKServiceError: Error {
        case recordNotFound
        case invalidZone
        case userNotFound
    }

    private struct RecordType {
        static let group = "Group"
        static let member = "Member"
        static let sessionRecord = "SessionRecord"
        static let taskUsageSummary = "TaskUsageSummary"
        static let appUsage = "AppUsage"
    }
    
    // グループの存在を確認する関数
    func verifyGroupExists(groupID: String) async -> Bool {
        print("\n🔍 === VERIFYING GROUP EXISTS ===")
        print("🆔 Group ID: \(groupID)")
        
        let db = CKContainer.default().publicCloudDatabase
        let groupRecordID = CKRecord.ID(recordName: groupID)
        
        do {
            // 直接フェッチを試みる
            let _ = try await db.record(for: groupRecordID)
            print("✅ Group exists!")
            return true
        } catch {
            print("❌ Direct fetch failed, trying query...")
            
            // クエリでも試す
            let predicate = NSPredicate(format: "recordID.recordName == %@", groupID)
            let query = CKQuery(recordType: RecordType.group, predicate: predicate)
            
            do {
                let records = try await performQuery(query, in: db)
                if !records.isEmpty {
                    print("✅ Group found via query!")
                    return true
                } else {
                    print("❌ Group not found via query")
                    return false
                }
            } catch {
                print("❌ Query also failed: \(error)")
                return false
            }
        }
    }
    
    // すべてのグループをリストする関数
    func listAllGroups() async -> [(id: String, name: String, owner: String)] {
        print("\n📋 === LISTING ALL GROUPS ===")
        
        let db = CKContainer.default().publicCloudDatabase
        let query = CKQuery(recordType: RecordType.group, predicate: NSPredicate(value: true))
        
        do {
            let records = try await performQuery(query, in: db)
            print("📦 Found \(records.count) groups")
            
            let groups = records.compactMap { record -> (String, String, String)? in
                guard let groupName = record["groupName"] as? String,
                      let ownerName = record["ownerName"] as? String else {
                    return nil
                }
                let id = record.recordID.recordName
                print("  - ID: \(id), Name: \(groupName), Owner: \(ownerName)")
                return (id, groupName, ownerName)
            }
            
            return groups
        } catch {
            print("❌ Failed to list groups: \(error)")
            return []
        }
    }
    
    // CloudKitServiceクラス内に追加
    func debugPrintCurrentEnvironment() {
        print("=== CloudKit Environment Debug ===")
        print("Is Using Shared Zone: \(isUsingSharedZone)")
        print("Current Zone ID: \(currentZoneID)")
        print("Current Database: \(currentDatabase == CKContainer.default().sharedCloudDatabase ? "Shared" : "Private")")
        
        if let zoneName = UserDefaults.standard.string(forKey: "sharedZoneName"),
           let ownerName = UserDefaults.standard.string(forKey: "sharedZoneOwner") {
            print("Shared Zone: \(zoneName) owned by \(ownerName)")
        }
        print("================================")
    }

    func createGroup(ownerName: String, groupName: String) async throws -> (url: URL, groupID: String) {
        let groupID = UUID().uuidString
        
        print("🔵 Creating group with ID: \(groupID)")
        
        // 環境確認
        #if DEBUG
        print("🏗️ [Creator] Build Configuration: DEBUG")
        #else
        print("🏗️ [Creator] Build Configuration: RELEASE")
        #endif
        
        let container = CKContainer.default()
        print("📱 [Creator] Container ID: \(container.containerIdentifier ?? "unknown")")
        
        if let userID = try? await container.userRecordID() {
            print("👤 [Creator] User Record ID: \(userID.recordName)")
        }
        
        if usePublicDatabase {
            print("\n🚀 === CREATING GROUP IN PUBLIC DATABASE ===")
            print("📝 Group ID: \(groupID)")
            print("📝 Group Name: \(groupName)")
            print("📝 Owner Name: \(ownerName)")
            
            // パブリックデータベースを使用する場合
            let groupRecordID = CKRecord.ID(recordName: groupID)
            let groupRecord = CKRecord(recordType: RecordType.group, recordID: groupRecordID)
            groupRecord["groupName"] = groupName as CKRecordValue
            groupRecord["ownerName"] = ownerName as CKRecordValue
            groupRecord["createdAt"] = Date() as CKRecordValue
            
            print("📋 Created Group Record:")
            print("   Record Type: \(groupRecord.recordType)")
            print("   Record ID: \(groupRecord.recordID.recordName)")
            
            // グループレコードを保存
            let db = CKContainer.default().publicCloudDatabase
            
            do {
                print("⏳ Saving group record to public database...")
                let savedRecord = try await db.save(groupRecord)
                print("\n✅ === GROUP RECORD SAVED ===")
                print("🔑 Saved Record ID: \(savedRecord.recordID.recordName)")
                print("📝 Saved Group Name: \(savedRecord["groupName"] ?? "nil")")
                print("👤 Saved Owner Name: \(savedRecord["ownerName"] ?? "nil")")
                print("📅 Saved Created At: \(savedRecord["createdAt"] ?? "nil")")
            } catch {
                print("\n❌ === FAILED TO SAVE GROUP ===")
                print("🚨 Error: \(error)")
                if let ckError = error as? CKError {
                    print("🚨 CKError Code: \(ckError.code.rawValue)")
                    print("🚨 CKError Description: \(ckError.localizedDescription)")
                }
                throw error
            }
            
            // オーナー自身をメンバーとして登録
            let memberID = UUID().uuidString
            let memberRecordID = CKRecord.ID(recordName: memberID)
            let memberRecord = CKRecord(recordType: RecordType.member, recordID: memberRecordID)
            memberRecord["userName"] = ownerName as CKRecordValue
            memberRecord["groupID"] = groupID as CKRecordValue
            memberRecord["joinedAt"] = Date() as CKRecordValue
            
            do {
                let savedMember = try await db.save(memberRecord)
                print("✅ Member record saved successfully: \(savedMember.recordID)")
            } catch {
                print("❌ Failed to save member record: \(error)")
            }
            
            // 少し待機（同期のため）
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2秒待機
            
            // シンプルなURLスキームを返す
            let url = URL(string: "monitoringsystem://join/\(groupID)")!
            print("\n🔗 === SHARE URL GENERATED ===")
            print("📱 URL: \(url.absoluteString)")
            print("🔑 Group ID in URL: \(groupID)")
            
            // 作成直後に確認
            print("\n🔍 === VERIFYING GROUP CREATION ===")
            let exists = await verifyGroupExists(groupID: groupID)
            if exists {
                print("✅ Group verified successfully!")
            } else {
                print("⚠️ Group not immediately visible - may need sync time")
            }
            
            print("✅ Group creation complete!")
            return (url, groupID)
        } else {
            // 既存の実装（プライベートデータベース + シェア）
            
            // グループID（ゾーン名）を生成
            let groupZoneID = CKRecordZone.ID(zoneName: groupID, ownerName: CKCurrentUserDefaultName)
            
            // 新しいゾーンを作成
            let groupZone = CKRecordZone(zoneID: groupZoneID)
            
            let db = CKContainer.default().privateCloudDatabase
            
            // ゾーンを作成
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let zoneOp = CKModifyRecordZonesOperation(recordZonesToSave: [groupZone], recordZoneIDsToDelete: nil)
                zoneOp.modifyRecordZonesResultBlock = { result in
                    switch result {
                    case .success:
                        cont.resume(returning: ())
                    case .failure(let error):
                        cont.resume(throwing: error)
                    }
                }
                db.add(zoneOp)
            }
            
            // グループレコードの作成
            let groupRecordID = CKRecord.ID(recordName: groupID, zoneID: groupZoneID)
            let groupRecord = CKRecord(recordType: "Group", recordID: groupRecordID)
            groupRecord["groupName"] = groupName as CKRecordValue
            groupRecord["ownerName"] = ownerName as CKRecordValue
            
            // グループレコードベースのシェアを作成
            let share = CKShare(rootRecord: groupRecord)
            share[CKShare.SystemFieldKey.title] = groupName as CKRecordValue
            share["ownerName"] = ownerName as CKRecordValue
            share.publicPermission = .readWrite
            
            // オーナー自身のメンバーレコードを作成
            let ownerMemberID = CKRecord.ID(recordName: UUID().uuidString, zoneID: groupZoneID)
            let ownerMemberRecord = CKRecord(recordType: "Member", recordID: ownerMemberID)
            ownerMemberRecord["userName"] = ownerName as CKRecordValue
            ownerMemberRecord["groupRef"] = CKRecord.Reference(recordID: groupRecordID, action: .deleteSelf) as CKRecordValue
            
            // すべてを保存
            let op = CKModifyRecordsOperation(
                recordsToSave: [groupRecord, share, ownerMemberRecord],
                recordIDsToDelete: nil)
            op.savePolicy = .ifServerRecordUnchanged
            op.isAtomic = true
            
            return try await withCheckedThrowingContinuation { cont in
                op.modifyRecordsResultBlock = { result in
                    switch result {
                    case .success:
                        if let shareURL = share.url {
                            cont.resume(returning: (shareURL, groupID))
                        } else {
                            let fallbackURL = URL(string: "monitoringsystem://share/\(groupID)")!
                            cont.resume(returning: (fallbackURL, groupID))
                        }
                    case .failure(let error):
                        cont.resume(throwing: error)
                    }
                }
                db.add(op)
            }
        }
    }
    
    func acceptShare(from metadata: CKShare.Metadata) async throws {
        // パブリックデータベースモードでは不要
        if usePublicDatabase {
            print("⚠️ acceptShare called but public database mode is enabled")
            return
        }
        return try await withCheckedThrowingContinuation { continuation in
            let operation = CKAcceptSharesOperation(shareMetadatas: [metadata])
            
            operation.acceptSharesResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume(returning: ())
                    
                case .failure(let error):
                    if let ckError = error as? CKError {
                        switch ckError.code {
                        case .alreadyShared:
                            continuation.resume(returning: ())
                            return
                        default:
                            break
                        }
                    }
                    
                    continuation.resume(throwing: error)
                }
            }
            
            operation.qualityOfService = .userInitiated
            CKContainer.default().add(operation)
        }
    }
    
    func getSharedZoneID(from metadata: CKShare.Metadata) async throws -> CKRecordZone.ID? {
        // メタデータから共有ゾーンIDを取得
        // metadata.shareは非オプショナルなので直接アクセス
        let share = metadata.share
        
        // シェアがゾーンレベルの共有かどうかを確認
        // ゾーンレベルの共有の場合、recordIDのzoneIDを返す
        return share.recordID.zoneID
    }

    // 共有ゾーンでの操作用のデータベースを取得
    func getDatabaseForSharedZone() -> CKDatabase {
        // 共有されたデータは sharedCloudDatabase でアクセス
        return CKContainer.default().sharedCloudDatabase
    }

    
    private func convertToPortableSession(_ session: SessionRecordModel) -> PortableSessionRecord {
        let taskSummaries = session.taskSummaries ?? []
        let portableTasks = taskSummaries.compactMap { task in
            let appBreakdown = task.appBreakdown ?? []
            let portableApps = appBreakdown.map { app in
                PortableAppUsage(name: app.name, seconds: app.seconds)
            }
            
            return PortableTaskUsageSummary(
                reminderId: task.reminderId,
                taskName: task.taskName,
                isCompleted: task.isCompleted,
                startTime: task.startTime,
                endTime: task.endTime,
                totalSeconds: task.totalSeconds,
                comment: task.comment,
                appBreakdown: portableApps,
                parentTaskName: task.parentTaskName
            )
        }
        
        return PortableSessionRecord(
            endTime: session.endTime,
            completedCount: session.completedCount,
            taskSummaries: portableTasks
        )
    }

    func uploadSession(groupID: String, userName: String, sessionRecord: SessionRecordModel) async throws {
        let portableSession = convertToPortableSession(sessionRecord)
        
        if usePublicDatabase {
            // パブリックデータベースモードでは全員がアップロード可能
            if isOnline {
                try await uploadSessionDirectly(groupID: groupID, userName: userName, session: portableSession)
            } else {
                saveToTemporaryStorage(groupID: groupID, userName: userName, session: portableSession)
            }
            return
        }
        
        // 既存の実装（共有データベースの制限あり）
        if currentDatabase == CKContainer.default().sharedCloudDatabase {
            print("📌 Member trying to upload - saving to temporary storage")
            saveToTemporaryStorage(groupID: groupID, userName: userName, session: portableSession)
            print("ℹ️ Data saved locally. Owner needs to implement data collection mechanism.")
            return
        }
        
        if isOnline {
            try await uploadSessionDirectly(groupID: groupID, userName: userName, session: portableSession)
        } else {
            saveToTemporaryStorage(groupID: groupID, userName: userName, session: portableSession)
        }
    }

    private func uploadSessionDirectly(groupID: String, userName: String, session: PortableSessionRecord) async throws {
        let db = currentDatabase
        
        // メンバーIDを取得または作成
        let memberID = try await createOrUpdateMember(groupID: groupID, userName: userName)
        
        var recordsToSave: [CKRecord] = []
        
        // セッションレコードの作成
        let sessionRecordID = CKRecord.ID(recordName: UUID().uuidString)
        let sessionRecord = CKRecord(recordType: RecordType.sessionRecord, recordID: sessionRecordID)
        
        if usePublicDatabase {
            // パブリックデータベースモードでは groupID と memberID を直接保存
            sessionRecord["groupID"] = groupID as CKRecordValue
            sessionRecord["memberID"] = memberID as CKRecordValue
            sessionRecord["userName"] = userName as CKRecordValue  // クエリを簡単にするため
        } else {
            // 既存の実装（Reference を使用）
            let zoneID = currentZoneID
            let memberRecordID = CKRecord.ID(recordName: memberID, zoneID: zoneID)
            let memberRef = CKRecord.Reference(recordID: memberRecordID, action: .deleteSelf)
            sessionRecord["memberRef"] = memberRef as CKRecordValue
        }
        
        sessionRecord["endTime"] = session.endTime as CKRecordValue
        sessionRecord["completedCount"] = session.completedCount as CKRecordValue
        recordsToSave.append(sessionRecord)
        
        // タスクとアプリ使用状況の保存処理
        for task in session.taskSummaries {
            let taskRecordID = CKRecord.ID(recordName: UUID().uuidString)
            let taskRecord = CKRecord(recordType: RecordType.taskUsageSummary, recordID: taskRecordID)
            
            if usePublicDatabase {
                taskRecord["sessionID"] = sessionRecordID.recordName as CKRecordValue
                taskRecord["groupID"] = groupID as CKRecordValue
            } else {
                let sessionRef = CKRecord.Reference(recordID: sessionRecordID, action: .deleteSelf)
                taskRecord["sessionRef"] = sessionRef as CKRecordValue
            }
            
            taskRecord["reminderId"] = task.reminderId as CKRecordValue
            taskRecord["taskName"] = task.taskName as CKRecordValue
            taskRecord["isCompleted"] = task.isCompleted as CKRecordValue
            taskRecord["startTime"] = task.startTime as CKRecordValue
            taskRecord["endTime"] = task.endTime as CKRecordValue
            taskRecord["totalSeconds"] = task.totalSeconds as CKRecordValue
            if let comment = task.comment {
                taskRecord["comment"] = comment as CKRecordValue
            }
            if let parentTaskName = task.parentTaskName {
                taskRecord["parentTaskName"] = parentTaskName as CKRecordValue
            }
            recordsToSave.append(taskRecord)
            
            // アプリ使用状況の保存
            for app in task.appBreakdown {
                let appRecordID = CKRecord.ID(recordName: UUID().uuidString)
                let appRecord = CKRecord(recordType: RecordType.appUsage, recordID: appRecordID)
                
                if usePublicDatabase {
                    appRecord["taskID"] = taskRecordID.recordName as CKRecordValue
                    appRecord["groupID"] = groupID as CKRecordValue
                } else {
                    let taskRef = CKRecord.Reference(recordID: taskRecordID, action: .deleteSelf)
                    appRecord["taskRef"] = taskRef as CKRecordValue
                }
                
                appRecord["name"] = app.name as CKRecordValue
                appRecord["seconds"] = app.seconds as CKRecordValue
                recordsToSave.append(appRecord)
            }
        }
        
        try await uploadRecordsInBatches(recordsToSave, to: db)
    }

    private func saveToTemporaryStorage(groupID: String, userName: String, session: PortableSessionRecord) {
        let offlineData = OfflineSessionData(groupID: groupID, userName: userName, sessionData: session)
        pendingUploads.append(offlineData)
        savePendingUploads()
    }
    
    private func savePendingUploads() {
        do {
            let data = try JSONEncoder().encode(pendingUploads)
            try FileManager.default.createDirectory(at: tempDataURL.deletingLastPathComponent(),
                                                   withIntermediateDirectories: true)
            try data.write(to: tempDataURL)
        } catch {
            lastError = "一時データの保存に失敗しました: \(error.localizedDescription)"
            
            NotificationCenter.default.post(
                name: Notification.Name("CloudKitLocalSaveError"),
                object: nil,
                userInfo: ["error": error.localizedDescription]
            )
        }
    }
    
    private func loadPendingUploads() {
        guard FileManager.default.fileExists(atPath: tempDataURL.path) else {
            return
        }
        
        do {
            let data = try Data(contentsOf: tempDataURL)
            pendingUploads = try JSONDecoder().decode([OfflineSessionData].self, from: data)
        } catch {
            pendingUploads = []
        }
    }
    
    private func uploadPendingData() async {
        guard !pendingUploads.isEmpty else {
            return
        }
        
        var successfulUploads: [UUID] = []
        var failedUploads: [(UUID, Error)] = []
        
        for upload in pendingUploads {
            do {
                try await uploadSessionDirectly(groupID: upload.groupID,
                                              userName: upload.userName,
                                              session: upload.sessionData)
                successfulUploads.append(upload.id)
            } catch {
                failedUploads.append((upload.id, error))
            }
        }
        
        pendingUploads.removeAll { upload in
            successfulUploads.contains(upload.id)
        }
        
        if !failedUploads.isEmpty {
            let errorMessages = failedUploads.map {
                "アップロードID \($0.0): \($0.1.localizedDescription)"
            }.joined(separator: "\n")
            
            await MainActor.run {
                lastError = "一部のデータのアップロードに失敗しました:\n\(errorMessages)"
            }
            
            NotificationCenter.default.post(
                name: Notification.Name("CloudKitUploadError"),
                object: nil,
                userInfo: [
                    "error": errorMessages,
                    "failedCount": failedUploads.count
                ]
            )
        }
        
        savePendingUploads()
    }
    
    
    func debugShareAndZoneInfo() async {
        print("\n🔍 === Share and Zone Debug Info ===")
        print("📦 isUsingSharedZone: \(isUsingSharedZone)")
        print("🏷️ currentZoneID: \(currentZoneID)")
        print("💾 currentDatabase: \(currentDatabase == CKContainer.default().sharedCloudDatabase ? "Shared" : "Private")")
        
        // UserDefaultsの内容を確認
        print("\n📋 UserDefaults:")
        print("  currentGroupID: \(UserDefaults.standard.string(forKey: "currentGroupID") ?? "nil")")
        print("  sharedZoneName: \(UserDefaults.standard.string(forKey: "sharedZoneName") ?? "nil")")
        print("  sharedZoneOwner: \(UserDefaults.standard.string(forKey: "sharedZoneOwner") ?? "nil")")
        
        // 利用可能なゾーンを確認
        print("\n🗂️ Available Zones:")
        
        // Privateデータベースのゾーン
        let privateDB = CKContainer.default().privateCloudDatabase
        do {
            let privateZones = try await privateDB.allRecordZones()
            print("  Private zones: \(privateZones.map { $0.zoneID })")
        } catch {
            print("  ❌ Failed to fetch private zones: \(error)")
        }
        
        // Sharedデータベースのゾーン
        let sharedDB = CKContainer.default().sharedCloudDatabase
        do {
            let sharedZones = try await sharedDB.allRecordZones()
            print("  Shared zones: \(sharedZones.map { $0.zoneID })")
        } catch {
            print("  ❌ Failed to fetch shared zones: \(error)")
        }
        
        print("===================================\n")
    }
    
    // メンバーとして参加している場合は、自分の情報をローカルに保存するだけ
    func registerAsLocalMember(groupID: String, userName: String) async throws -> String {
        print("📝 Registering as local member only (shared database limitation)")
        
        // ローカルに保存（UserDefaultsまたは別の方法で）
        UserDefaults.standard.set(userName, forKey: "localMemberName")
        UserDefaults.standard.set(groupID, forKey: "localGroupID")
        UserDefaults.standard.synchronize()
        
        // 仮のメンバーIDを返す
        let localMemberID = "LOCAL_\(UUID().uuidString)"
        return localMemberID
    }

    func createOrUpdateMember(groupID: String, userName: String) async throws -> String {
        print("\n👥 === CREATE OR UPDATE MEMBER ===")
        print("🆔 Group ID: \(groupID)")
        print("👤 User Name: \(userName)")
        print("🕐 Timestamp: \(Date())")
        
        await debugShareAndZoneInfo()
        
        if usePublicDatabase {
            print("\n🌐 Using PUBLIC DATABASE mode")
            let db = CKContainer.default().publicCloudDatabase
            
            // 既存のメンバーをチェック
            print("🔍 Checking for existing member...")
            if let existingMemberID = try await findMember(groupID: groupID, userName: userName) {
                print("✅ Existing member found: \(existingMemberID)")
                return existingMemberID
            }
            print("🆕 No existing member found, creating new...")
            
            // 新しいメンバーレコードを作成
            let memberID = UUID().uuidString
            let memberRecordID = CKRecord.ID(recordName: memberID)
            let memberRecord = CKRecord(recordType: RecordType.member, recordID: memberRecordID)
            
            print("\n🆕 Creating new member record:")
            print("🆔 Member ID: \(memberID)")
            print("📋 Record Type: \(RecordType.member)")
            memberRecord["userName"] = userName as CKRecordValue
            memberRecord["groupID"] = groupID as CKRecordValue
            memberRecord["joinedAt"] = Date() as CKRecordValue
            
            let savedRecord = try await db.save(memberRecord)
            print("✅ Member created successfully with ID: \(savedRecord.recordID.recordName)")
            return savedRecord.recordID.recordName
        } else {
            let db = currentDatabase
            
            // 共有データベースを使用している場合（メンバーとして参加）
            if db == CKContainer.default().sharedCloudDatabase {
                print("📌 Shared database detected - using local registration only")
                return try await registerAsLocalMember(groupID: groupID, userName: userName)
            }
            
            // プライベートデータベースの場合（オーナー）
            if !isUsingSharedZone {
                try await ensureZone()
            }
            
            let zoneID = currentZoneID
            
            // 既存のメンバーをチェック
            if let existingMemberID = try await findMember(groupID: groupID, userName: userName) {
                print("✅ Existing member found: \(existingMemberID)")
                return existingMemberID
            }
            
            // 新しいメンバーレコードを作成
            let memberRecordID = CKRecord.ID(recordName: UUID().uuidString, zoneID: zoneID)
            let memberRecord = CKRecord(recordType: RecordType.member, recordID: memberRecordID)
            memberRecord["userName"] = userName as CKRecordValue
            
            let groupRecordID = CKRecord.ID(recordName: groupID, zoneID: zoneID)
            let groupRef = CKRecord.Reference(recordID: groupRecordID, action: .deleteSelf)
            memberRecord["groupRef"] = groupRef as CKRecordValue
            
            // レコードを保存
            do {
                let savedRecord = try await db.save(memberRecord)
                print("✅ Member created successfully with ID: \(savedRecord.recordID.recordName)")
                return savedRecord.recordID.recordName
            } catch {
                print("❌ Member creation failed: \(error)")
                throw error
            }
        }
    }
    
    private func findMember(groupID: String, userName: String) async throws -> String? {
        print("\n🔍 === FINDING MEMBER ===")
        print("🆔 Group ID: \(groupID)")
        print("👤 User Name: \(userName)")
        
        if usePublicDatabase {
            // パブリックデータベースモードの処理
            let db = CKContainer.default().publicCloudDatabase
            let predicate = NSPredicate(format: "groupID == %@ AND userName == %@", groupID, userName)
            let query = CKQuery(recordType: RecordType.member, predicate: predicate)
            
            print("🔍 Query predicate: groupID == '\(groupID)' AND userName == '\(userName)'")
            print("📋 Record Type: \(RecordType.member)")
            
            let records = try await performQuery(query, in: db)
            print("📑 Found \(records.count) matching member(s)")
            
            if let memberID = records.first?.recordID.recordName {
                print("✅ Member exists with ID: \(memberID)")
            } else {
                print("❌ No existing member found")
            }
            
            return records.first?.recordID.recordName
        } else {
            let db = currentDatabase
            
            // 共有データベースの場合、クエリ条件を調整
            let predicate: NSPredicate
            if db == CKContainer.default().sharedCloudDatabase {
                // 共有データベースではuserNameのみで検索し、結果をフィルタリング
                predicate = NSPredicate(format: "userName == %@", userName)
            } else {
                // プライベートデータベースでは従来通り
                let zoneID = currentZoneID
                let groupRecordID = CKRecord.ID(recordName: groupID, zoneID: zoneID)
                let groupRef = CKRecord.Reference(recordID: groupRecordID, action: .deleteSelf)
                predicate = NSPredicate(format: "groupRef == %@ AND userName == %@", groupRef, userName)
            }
            
            let query = CKQuery(recordType: RecordType.member, predicate: predicate)
            
            // performQueryを使用
            let records = try await performQuery(query, in: db)
            
            // 共有データベースの場合、取得したレコードから正しいゾーンのものをフィルタリング
            if db == CKContainer.default().sharedCloudDatabase {
                let targetZoneID = currentZoneID
                let filteredRecords = records.filter { record in
                    return record.recordID.zoneID == targetZoneID
                }
                
                print("   Filtered \(filteredRecords.count) records for zone: \(targetZoneID)")
                
                if let first = filteredRecords.first {
                    return first.recordID.recordName
                }
            } else {
                if let first = records.first {
                    return first.recordID.recordName
                }
            }
            
            return nil
        }
    }
    
    private func uploadRecordsInBatches(_ records: [CKRecord], to database: CKDatabase) async throws {
        let batchSize = 400
        
        for chunk in records.chunked(into: batchSize) {
            let operation = CKModifyRecordsOperation(recordsToSave: chunk, recordIDsToDelete: nil)
            operation.savePolicy = .ifServerRecordUnchanged
            operation.isAtomic = false
            
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                operation.modifyRecordsResultBlock = { result in
                    switch result {
                    case .success:
                        continuation.resume(returning: ())
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
                
                database.add(operation) // 指定されたデータベースを使用
            }
        }
    }

    func fetchGroupMembers(groupID: String) async throws -> [String] {
        guard !groupID.isEmpty else {
            return []
        }
        
        if usePublicDatabase {
            // パブリックデータベースモードで全メンバーを取得
            print("📌 Fetching all members from public database")
            
            let db = CKContainer.default().publicCloudDatabase
            let predicate = NSPredicate(format: "groupID == %@", groupID)
            let query = CKQuery(recordType: RecordType.member, predicate: predicate)
            query.sortDescriptors = [NSSortDescriptor(key: "userName", ascending: true)]
            
            let memberRecords = try await performQuery(query, in: db)
            
            let memberNames = memberRecords.compactMap { record in
                record["userName"] as? String
            }
            
            // 重複を除去してソート
            let uniqueNames = Array(Set(memberNames)).sorted()
            
            print("✅ Found \(uniqueNames.count) members: \(uniqueNames)")
            return uniqueNames
        }
        
        // 既存の実装（制限あり）
        var memberNames: Set<String> = []
        
        if currentDatabase == CKContainer.default().sharedCloudDatabase {
            print("📌 Fetching members from shared database")
            
            if let localUserName = UserDefaults.standard.string(forKey: "userName") {
                memberNames.insert(localUserName)
            }
            
            let sharedDB = CKContainer.default().sharedCloudDatabase
            let sharedZoneName = UserDefaults.standard.string(forKey: "sharedZoneName") ?? ""
            let sharedZoneOwner = UserDefaults.standard.string(forKey: "sharedZoneOwner") ?? ""
            let sharedZoneID = CKRecordZone.ID(zoneName: sharedZoneName, ownerName: sharedZoneOwner)
            let groupRecordID = CKRecord.ID(recordName: groupID, zoneID: sharedZoneID)
            
            do {
                let groupRecord = try await currentDatabase.record(for: groupRecordID)
                if let ownerName = groupRecord["ownerName"] as? String {
                    memberNames.insert(ownerName)
                }
            } catch {
                print("⚠️ Could not fetch group record from shared database: \(error)")
                
                if let groupInfo = GroupInfoStore.shared.groupInfo,
                   groupInfo.recordID == groupID {
                    memberNames.insert(groupInfo.ownerName)
                }
            }
            
            print("ℹ️ Note: Full member list is only available to the owner")
            
            return Array(memberNames).sorted()
        }
        
        // 共有データベースの場合
        if currentDatabase == CKContainer.default().sharedCloudDatabase {
            print("📌 Fetching members from shared database")
            
            // 自分のローカル名を追加
            if let localUserName = UserDefaults.standard.string(forKey: "userName") {
                memberNames.insert(localUserName)
            }
            
            // 共有されているグループレコードからオーナー名を取得
            let zoneID = currentZoneID
            let groupRecordID = CKRecord.ID(recordName: groupID, zoneID: zoneID)
            
            do {
                let groupRecord = try await currentDatabase.record(for: groupRecordID)
                if let ownerName = groupRecord["ownerName"] as? String {
                    memberNames.insert(ownerName)
                }
            } catch {
                print("⚠️ Could not fetch group record from shared database: \(error)")
                
                // フォールバック：GroupInfoStoreから情報を取得
                if let groupInfo = GroupInfoStore.shared.groupInfo,
                   groupInfo.recordID == groupID {
                    memberNames.insert(groupInfo.ownerName)
                }
            }
            
            // 他のメンバーは共有データベースからは取得できない
            print("ℹ️ Note: Full member list is only available to the owner")
            
            return Array(memberNames).sorted()
        }
        
        // プライベートデータベースの場合（オーナー）
        if !isUsingSharedZone {
            try await ensureZone()
        }
        
        let db = currentDatabase
        let zoneID = currentZoneID
        
        // グループレコードを取得してオーナー名を追加
        let groupRecordID = CKRecord.ID(recordName: groupID, zoneID: zoneID)
        
        do {
            let groupRecord = try await db.record(for: groupRecordID)
            if let ownerName = groupRecord["ownerName"] as? String {
                memberNames.insert(ownerName)
            }
        } catch {
            // グループレコードが見つからない場合は続行
        }
        
        // メンバーレコードを取得
        let groupRef = CKRecord.Reference(recordID: groupRecordID, action: .deleteSelf)
        let memberPredicate = NSPredicate(format: "groupRef == %@", groupRef)
        let memberQuery = CKQuery(recordType: RecordType.member, predicate: memberPredicate)
        memberQuery.sortDescriptors = [NSSortDescriptor(key: "userName", ascending: true)]
        
        let memberRecords = try await performQuery(memberQuery, in: db)
        
        let recordMemberNames = memberRecords.compactMap { record in
            record["userName"] as? String
        }
        
        recordMemberNames.forEach { memberNames.insert($0) }
        
        return Array(memberNames).sorted()
    }
        
    
    func fetchUserSummaries(groupID: String, userName: String, forDays days: Int) async throws -> ([TaskUsageSummary], Int) {
        print("📊 Fetching summaries for user: \(userName) in group: \(groupID)")
        
        guard !groupID.isEmpty && !userName.isEmpty else {
            print("❌ Empty groupID or userName")
            return ([], 0)
        }
        
        if usePublicDatabase {
            // パブリックデータベースモードで全データにアクセス可能
            print("📌 Using public database - full access to all data")
            
            let db = CKContainer.default().publicCloudDatabase
            let cache = CloudKitCacheStore.shared
            
            // キャッシュからデータを取得
            let cachedSummaries = await cache.loadCachedSummaries(groupID: groupID, userName: userName, forDays: days)
            
            // 日付範囲の計算
            let calendar = Calendar.current
            let startOfToday = calendar.startOfDay(for: Date())
            let fromDate = calendar.date(byAdding: .day, value: -(days - 1), to: startOfToday)!
            
            // セッションレコードを取得
            let sessionPredicate = NSPredicate(format: "groupID == %@ AND userName == %@ AND endTime >= %@",
                                             groupID, userName, fromDate as NSDate)
            let sessionQuery = CKQuery(recordType: RecordType.sessionRecord, predicate: sessionPredicate)
            sessionQuery.sortDescriptors = [NSSortDescriptor(key: "endTime", ascending: false)]
            
            let sessionRecords = try await performQuery(sessionQuery, in: db)
            
            var allSummaries: [TaskUsageSummary] = []
            
            for sessionRecord in sessionRecords {
                let sessionID = sessionRecord.recordID.recordName
                let taskSummaries = try await fetchTaskSummariesPublic(sessionID: sessionID, groupID: groupID, in: db)
                allSummaries.append(contentsOf: taskSummaries)
                
                let sessionEndTime = sessionRecord["endTime"] as? Date ?? Date()
                await cache.saveTaskSummaries(taskSummaries, groupID: groupID, userName: userName, sessionEndTime: sessionEndTime)
            }
            
            // データをマージ
            var merged: [String: TaskUsageSummary] = [:]
            
            // キャッシュデータとCloudKitデータをマージ
            for task in cachedSummaries + allSummaries {
                let key = task.reminderId.isEmpty ? task.taskName : task.reminderId
                
                if var existing = merged[key] {
                    existing.totalSeconds += task.totalSeconds
                    existing.appBreakdown = mergeAppUsage(existing.appBreakdown, task.appBreakdown)
                    existing.isCompleted = existing.isCompleted || task.isCompleted
                    
                    if existing.comment?.isEmpty ?? true, let newComment = task.comment, !newComment.isEmpty {
                        existing.comment = newComment
                    }
                    
                    if existing.parentTaskName == nil, let newParentTaskName = task.parentTaskName {
                        existing.parentTaskName = newParentTaskName
                    }
                    
                    existing.endTime = max(existing.endTime, task.endTime)
                    existing.startTime = min(existing.startTime, task.startTime)
                    
                    merged[key] = existing
                } else {
                    merged[key] = task
                }
            }
            
            let mergedCompletedCount = merged.values.filter { $0.isCompleted }.count
            let sortedTasks = Array(merged.values).sorted { $0.totalSeconds > $1.totalSeconds }
            
            return (sortedTasks, mergedCompletedCount)
        }
        
        // 共有データベースの場合、データは読み取れない
        if currentDatabase == CKContainer.default().sharedCloudDatabase {
            print("ℹ️ Shared database - no data available for members")
            // キャッシュからのみデータを取得
            let cache = CloudKitCacheStore.shared
            let cachedSummaries = await cache.loadCachedSummaries(groupID: groupID, userName: userName, forDays: days)
            let completedCount = cachedSummaries.filter { $0.isCompleted }.count
            return (cachedSummaries, completedCount)
        }
        
        try await ensureZone()
        
        let cache = CloudKitCacheStore.shared
        
        let cachedSummaries = await cache.loadCachedSummaries(groupID: groupID, userName: userName, forDays: days)
        
        // 使用するデータベースとゾーンIDを決定
        let db = currentDatabase
        let zoneID = currentZoneID
        
        // メンバーIDを取得
        guard let memberID = try await findMember(groupID: groupID, userName: userName) else {
            return (cachedSummaries, cachedSummaries.filter { $0.isCompleted }.count)
        }
        
        let memberRecordID = CKRecord.ID(recordName: memberID, zoneID: zoneID)
        let memberRef = CKRecord.Reference(recordID: memberRecordID, action: .deleteSelf)
        
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let fromDate = calendar.date(byAdding: .day, value: -(days - 1), to: startOfToday)!
        
        // セッションレコードを取得
        let sessionPredicate = NSPredicate(format: "memberRef == %@ AND endTime >= %@", memberRef, fromDate as NSDate)
        let sessionQuery = CKQuery(recordType: RecordType.sessionRecord, predicate: sessionPredicate)
        sessionQuery.sortDescriptors = [NSSortDescriptor(key: "endTime", ascending: false)]
        
        let sessionRecords = try await performQuery(sessionQuery, in: db)
        
        var allSummaries: [TaskUsageSummary] = []
        
        for sessionRecord in sessionRecords {
            let sessionRef = CKRecord.Reference(recordID: sessionRecord.recordID, action: .deleteSelf)
            let taskSummaries = try await fetchTaskSummariesForManagement(sessionRef: sessionRef, in: db)
            allSummaries.append(contentsOf: taskSummaries)
            
            let sessionEndTime = sessionRecord["endTime"] as? Date ?? Date()
            await cache.saveTaskSummaries(taskSummaries, groupID: groupID, userName: userName, sessionEndTime: sessionEndTime)
        }
        
        // データをマージして返す
        var merged: [String: TaskUsageSummary] = [:]
        
        for task in allSummaries {
            let key = task.reminderId.isEmpty ? task.taskName : task.reminderId
            
            if var existing = merged[key] {
                existing.totalSeconds += task.totalSeconds
                existing.appBreakdown = mergeAppUsage(existing.appBreakdown, task.appBreakdown)
                existing.isCompleted = existing.isCompleted || task.isCompleted
                
                if existing.comment?.isEmpty ?? true, let newComment = task.comment, !newComment.isEmpty {
                    existing.comment = newComment
                }
                
                if existing.parentTaskName == nil, let newParentTaskName = task.parentTaskName {
                    existing.parentTaskName = newParentTaskName
                }
                
                existing.endTime = max(existing.endTime, task.endTime)
                existing.startTime = min(existing.startTime, task.startTime)
                
                merged[key] = existing
            } else {
                merged[key] = task
            }
        }
        
        let mergedCompletedCount = merged.values.filter { $0.isCompleted }.count
        let sortedTasks = Array(merged.values).sorted { $0.totalSeconds > $1.totalSeconds }
        
        return (sortedTasks, mergedCompletedCount)
    }
    
    // パブリックデータベース用のタスクサマリー取得メソッド
    private func fetchTaskSummariesPublic(sessionID: String, groupID: String, in database: CKDatabase) async throws -> [TaskUsageSummary] {
        let taskPredicate = NSPredicate(format: "sessionID == %@ AND groupID == %@", sessionID, groupID)
        let taskQuery = CKQuery(recordType: RecordType.taskUsageSummary, predicate: taskPredicate)
        
        let taskRecords = try await performQuery(taskQuery, in: database)
        
        var tasks: [TaskUsageSummary] = []
        
        for taskRecord in taskRecords {
            guard let reminderId = taskRecord["reminderId"] as? String,
                  let taskName = taskRecord["taskName"] as? String,
                  let isCompleted = taskRecord["isCompleted"] as? Bool,
                  let startTime = taskRecord["startTime"] as? Date,
                  let endTime = taskRecord["endTime"] as? Date,
                  let totalSeconds = taskRecord["totalSeconds"] as? Double else { continue }
            
            let comment = taskRecord["comment"] as? String
            let parentTaskName = taskRecord["parentTaskName"] as? String
            
            let taskID = taskRecord.recordID.recordName
            let appUsages = try await fetchAppUsagesPublic(taskID: taskID, groupID: groupID, in: database)
            
            let task = TaskUsageSummary(
                reminderId: reminderId,
                taskName: taskName,
                isCompleted: isCompleted,
                startTime: startTime,
                endTime: endTime,
                totalSeconds: totalSeconds,
                comment: comment,
                appBreakdown: appUsages,
                parentTaskName: parentTaskName
            )
            tasks.append(task)
        }
        
        return tasks
    }

    // パブリックデータベース用のアプリ使用状況取得メソッド
    private func fetchAppUsagesPublic(taskID: String, groupID: String, in database: CKDatabase) async throws -> [AppUsage] {
        let appPredicate = NSPredicate(format: "taskID == %@ AND groupID == %@", taskID, groupID)
        let appQuery = CKQuery(recordType: RecordType.appUsage, predicate: appPredicate)
        
        let appRecords = try await performQuery(appQuery, in: database)
        
        var apps: [AppUsage] = []
        
        for appRecord in appRecords {
            guard let name = appRecord["name"] as? String,
                  let seconds = appRecord["seconds"] as? Double else { continue }
            
            let app = AppUsage(name: name, seconds: seconds)
            apps.append(app)
        }
        
        return apps
    }

    private func fetchUserSummariesFullSync(groupID: String, userName: String, forDays days: Int) async throws -> ([TaskUsageSummary], Int) {
        guard let memberID = try await findMember(groupID: groupID, userName: userName) else {
            return ([], 0)
        }
        
        let db = currentDatabase
        let zoneID = currentZoneID
        
        let memberRecordID = CKRecord.ID(recordName: memberID, zoneID: zoneID)
        let memberRef = CKRecord.Reference(recordID: memberRecordID, action: .deleteSelf)
        
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let fromDate = calendar.date(byAdding: .day, value: -(days - 1), to: startOfToday)!
        
        let sessionPredicate = NSPredicate(format: "memberRef == %@ AND endTime >= %@", memberRef, fromDate as NSDate)
        let sessionQuery = CKQuery(recordType: RecordType.sessionRecord, predicate: sessionPredicate)
        sessionQuery.sortDescriptors = [NSSortDescriptor(key: "endTime", ascending: false)]
        
        let sessionRecords = try await performQuery(sessionQuery, in: db)
        
        var allSummaries: [TaskUsageSummary] = []
        let cache = CloudKitCacheStore.shared
        
        for sessionRecord in sessionRecords {
            let sessionRef = CKRecord.Reference(recordID: sessionRecord.recordID, action: .deleteSelf)
            let taskSummaries = try await fetchTaskSummariesForManagement(sessionRef: sessionRef, in: db)  // dbパラメータを追加
            allSummaries.append(contentsOf: taskSummaries)
            
            let sessionEndTime = sessionRecord["endTime"] as? Date ?? Date()
            await cache.saveTaskSummaries(taskSummaries, groupID: groupID, userName: userName, sessionEndTime: sessionEndTime)
        }
        
        var merged: [String: TaskUsageSummary] = [:]
        
        for task in allSummaries {
            let key = task.reminderId.isEmpty ? task.taskName : task.reminderId
            
            if var existing = merged[key] {
                existing.totalSeconds += task.totalSeconds
                existing.appBreakdown = mergeAppUsage(existing.appBreakdown, task.appBreakdown)
                existing.isCompleted = existing.isCompleted || task.isCompleted
                
                if existing.comment?.isEmpty ?? true, let newComment = task.comment, !newComment.isEmpty {
                    existing.comment = newComment
                }
                
                if existing.parentTaskName == nil, let newParentTaskName = task.parentTaskName {
                    existing.parentTaskName = newParentTaskName
                }
                
                existing.endTime = max(existing.endTime, task.endTime)
                existing.startTime = min(existing.startTime, task.startTime)
                
                merged[key] = existing
            } else {
                merged[key] = task
            }
        }
        
        let mergedCompletedCount = merged.values.filter { $0.isCompleted }.count
        let sortedTasks = Array(merged.values).sorted { $0.totalSeconds > $1.totalSeconds }
        
        return (sortedTasks, mergedCompletedCount)
    }
    
    private func fetchTaskSummariesForManagement(sessionRef: CKRecord.Reference, in database: CKDatabase) async throws -> [TaskUsageSummary] {
        let taskPredicate = NSPredicate(format: "sessionRef == %@", sessionRef)
        let taskQuery = CKQuery(recordType: RecordType.taskUsageSummary, predicate: taskPredicate)
        
        let taskRecords = try await performQuery(taskQuery, in: database)
        
        var tasks: [TaskUsageSummary] = []
        
        for taskRecord in taskRecords {
            guard let reminderId = taskRecord["reminderId"] as? String,
                  let taskName = taskRecord["taskName"] as? String,
                  let isCompleted = taskRecord["isCompleted"] as? Bool,
                  let startTime = taskRecord["startTime"] as? Date,
                  let endTime = taskRecord["endTime"] as? Date,
                  let totalSeconds = taskRecord["totalSeconds"] as? Double else { continue }
            let comment = taskRecord["comment"] as? String
            let parentTaskName = taskRecord["parentTaskName"] as? String
            
            let taskRef = CKRecord.Reference(recordID: taskRecord.recordID, action: .deleteSelf)
            let appUsages = try await fetchAppUsagesForManagement(taskRef: taskRef, in: database)
            
            let task = TaskUsageSummary(
                reminderId: reminderId,
                taskName: taskName,
                isCompleted: isCompleted,
                startTime: startTime,
                endTime: endTime,
                totalSeconds: totalSeconds,
                comment: comment,
                appBreakdown: appUsages,
                parentTaskName: parentTaskName
            )
            tasks.append(task)
        }
        
        return tasks
    }

    private func fetchAppUsagesForManagement(taskRef: CKRecord.Reference, in database: CKDatabase) async throws -> [AppUsage] {
        let appPredicate = NSPredicate(format: "taskRef == %@", taskRef)
        let appQuery = CKQuery(recordType: RecordType.appUsage, predicate: appPredicate)
        
        let appRecords = try await performQuery(appQuery, in: database)
        
        var apps: [AppUsage] = []
        
        for appRecord in appRecords {
            guard let name = appRecord["name"] as? String,
                  let seconds = appRecord["seconds"] as? Double else { continue }
            
            let app = AppUsage(name: name, seconds: seconds)
            apps.append(app)
        }
        
        return apps
    }
    
    private func mergeAppUsage(_ existing: [AppUsage], _ new: [AppUsage]) -> [AppUsage] {
        var merged: [String: Double] = [:]
        
        for app in existing {
            merged[app.name, default: 0] += app.seconds
        }
        
        for app in new {
            merged[app.name, default: 0] += app.seconds
        }
        
        return merged.map { AppUsage(name: $0.key, seconds: $0.value) }
    }

    func fetchAllGroupData(groupID: String) async throws -> [String: [PortableSessionRecord]] {
        try await ensureZone()
        
        let groupRecordID = CKRecord.ID(recordName: groupID, zoneID: Self.workZoneID)
        let groupRef = CKRecord.Reference(recordID: groupRecordID, action: .deleteSelf)
        
        let memberPredicate = NSPredicate(format: "groupRef == %@", groupRef)
        let memberQuery = CKQuery(recordType: RecordType.member, predicate: memberPredicate)
        
        let db = CKContainer.default().privateCloudDatabase
        let members = try await performQuery(memberQuery, in: db)
        
        var groupData: [String: [PortableSessionRecord]] = [:]
        
        for memberRecord in members {
            guard let userName = memberRecord["userName"] as? String else { continue }
            
            let memberRef = CKRecord.Reference(recordID: memberRecord.recordID, action: .deleteSelf)
            let sessionData = try await fetchUserSessionData(memberRef: memberRef)
            groupData[userName] = sessionData
        }
        
        return groupData
    }
    
    private func fetchUserSessionData(memberRef: CKRecord.Reference) async throws -> [PortableSessionRecord] {
        let sessionPredicate = NSPredicate(format: "memberRef == %@", memberRef)
        let sessionQuery = CKQuery(recordType: RecordType.sessionRecord, predicate: sessionPredicate)
        
        let db = CKContainer.default().privateCloudDatabase
        let sessionRecords = try await performQuery(sessionQuery, in: db)
        
        var sessions: [PortableSessionRecord] = []
        
        for sessionRecord in sessionRecords {
            guard let endTime = sessionRecord["endTime"] as? Date,
                  let completedCount = sessionRecord["completedCount"] as? Int else { continue }
            
            let sessionRef = CKRecord.Reference(recordID: sessionRecord.recordID, action: .deleteSelf)
            let taskSummaries = try await fetchTaskSummaries(sessionRef: sessionRef)
            
            let session = PortableSessionRecord(endTime: endTime,
                                              completedCount: completedCount,
                                              taskSummaries: taskSummaries)
            sessions.append(session)
        }
        
        return sessions
    }
    
    private func fetchTaskSummaries(sessionRef: CKRecord.Reference) async throws -> [PortableTaskUsageSummary] {
        let taskPredicate = NSPredicate(format: "sessionRef == %@", sessionRef)
        let taskQuery = CKQuery(recordType: RecordType.taskUsageSummary, predicate: taskPredicate)
        
        let db = CKContainer.default().privateCloudDatabase
        let taskRecords = try await performQuery(taskQuery, in: db)
        
        var tasks: [PortableTaskUsageSummary] = []
        
        for taskRecord in taskRecords {
            guard let reminderId = taskRecord["reminderId"] as? String,
                  let taskName = taskRecord["taskName"] as? String,
                  let isCompleted = taskRecord["isCompleted"] as? Bool,
                  let startTime = taskRecord["startTime"] as? Date,
                  let endTime = taskRecord["endTime"] as? Date,
                  let totalSeconds = taskRecord["totalSeconds"] as? Double else { continue }
            
            let comment = taskRecord["comment"] as? String
            let parentTaskName = taskRecord["parentTaskName"] as? String
            
            let taskRef = CKRecord.Reference(recordID: taskRecord.recordID, action: .deleteSelf)
            let appUsages = try await fetchAppUsages(taskRef: taskRef)
            
            let task = PortableTaskUsageSummary(reminderId: reminderId,
                                              taskName: taskName,
                                              isCompleted: isCompleted,
                                              startTime: startTime,
                                              endTime: endTime,
                                              totalSeconds: totalSeconds,
                                              comment: comment,
                                              appBreakdown: appUsages,
                                              parentTaskName: parentTaskName)
            tasks.append(task)
        }
        
        return tasks
    }
    
    private func fetchAppUsages(taskRef: CKRecord.Reference) async throws -> [PortableAppUsage] {
        let appPredicate = NSPredicate(format: "taskRef == %@", taskRef)
        let appQuery = CKQuery(recordType: RecordType.appUsage, predicate: appPredicate)
        
        let db = CKContainer.default().privateCloudDatabase
        let appRecords = try await performQuery(appQuery, in: db)
        
        var apps: [PortableAppUsage] = []
        
        for appRecord in appRecords {
            guard let name = appRecord["name"] as? String,
                  let seconds = appRecord["seconds"] as? Double else { continue }
            
            let app = PortableAppUsage(name: name, seconds: seconds)
            apps.append(app)
        }
        
        return apps
    }
    
    private func performQuery(_ query: CKQuery, in database: CKDatabase) async throws -> [CKRecord] {
        print("🔍 Performing query")
        print("   Record type: \(query.recordType)")
        // データベースタイプの判定を分けて記述
        let dbType: String
        if database == CKContainer.default().publicCloudDatabase {
            dbType = "Public"
        } else if database == CKContainer.default().sharedCloudDatabase {
            dbType = "Shared"
        } else {
            dbType = "Private"
        }
        print("   Database: \(dbType)")
        
        if usePublicDatabase {
            // パブリックデータベースでのクエリ実行
            var allRecords: [CKRecord] = []
            
            return try await withCheckedThrowingContinuation { continuation in
                let operation = CKQueryOperation(query: query)
                operation.resultsLimit = CKQueryOperation.maximumResults
                
                operation.recordMatchedBlock = { _, result in
                    switch result {
                    case .success(let record):
                        allRecords.append(record)
                    case .failure(let error):
                        print("   Error fetching record: \(error)")
                    }
                }
                
                operation.queryResultBlock = { result in
                    switch result {
                    case .success(let cursor):
                        print("   Found \(allRecords.count) records")
                        if let cursor = cursor {
                            // さらにレコードがある場合は続きを取得
                            self.fetchMoreRecords(cursor: cursor,
                                                database: database,
                                                records: allRecords) { finalRecords in
                                continuation.resume(returning: finalRecords)
                            }
                        } else {
                            continuation.resume(returning: allRecords)
                        }
                    case .failure(let error):
                        print("   Query failed: \(error)")
                        continuation.resume(throwing: error)
                    }
                }
                
                database.add(operation)
            }
        } else {
            // 共有データベースの場合
            if database == CKContainer.default().sharedCloudDatabase {
                // CKQueryOperationを使用してゾーンIDなしでクエリを実行
                var allRecords: [CKRecord] = []
                
                return try await withCheckedThrowingContinuation { continuation in
                    let operation = CKQueryOperation(query: query)
                    operation.resultsLimit = 1000
                    
                    // レコードを受信したときの処理
                    operation.recordMatchedBlock = { _, result in
                        switch result {
                        case .success(let record):
                            allRecords.append(record)
                        case .failure(let error):
                            print("   Error fetching record: \(error)")
                        }
                    }
                    
                    // クエリ完了時の処理
                    operation.queryResultBlock = { result in
                        switch result {
                        case .success:
                            print("   Found \(allRecords.count) records in shared database")
                            continuation.resume(returning: allRecords)
                        case .failure(let error):
                            print("   Query failed: \(error)")
                            continuation.resume(throwing: error)
                        }
                    }
                    
                    // 共有データベースで実行
                    database.add(operation)
                }
            } else {
                // プライベートデータベースの場合は従来通りゾーンIDを指定
                let zoneID = currentZoneID
                print("   Using zone: \(zoneID)")
                
                return try await withCheckedThrowingContinuation { continuation in
                    database.fetch(withQuery: query, inZoneWith: zoneID, desiredKeys: nil, resultsLimit: 1000) { result in
                        switch result {
                        case .success(let (matchResults, _)):
                            let records = matchResults.compactMap { (recordID, recordResult) in
                                if case .success(let record) = recordResult {
                                    return record
                                }
                                return nil
                            }
                            print("   Found \(records.count) records")
                            continuation.resume(returning: records)
                        case .failure(let error):
                            print("   Query failed: \(error)")
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }
        }
    }

    // 新しいヘルパーメソッド（performQuery の下に追加）
    private func fetchMoreRecords(cursor: CKQueryOperation.Cursor,
                                database: CKDatabase,
                                records: [CKRecord],
                                completion: @escaping ([CKRecord]) -> Void) {
        var allRecords = records
        
        let operation = CKQueryOperation(cursor: cursor)
        operation.resultsLimit = CKQueryOperation.maximumResults
        
        operation.recordMatchedBlock = { _, result in
            if case .success(let record) = result {
                allRecords.append(record)
            }
        }
        
        operation.queryResultBlock = { result in
            switch result {
            case .success(let newCursor):
                if let newCursor = newCursor {
                    self.fetchMoreRecords(cursor: newCursor,
                                        database: database,
                                        records: allRecords,
                                        completion: completion)
                } else {
                    completion(allRecords)
                }
            case .failure:
                completion(allRecords)
            }
        }
        
        database.add(operation)
    }

    private func deleteRecords(_ recordIDs: [CKRecord.ID]) async throws {
        let db = CKContainer.default().privateCloudDatabase
        let operation = CKModifyRecordsOperation(recordsToSave: nil, recordIDsToDelete: recordIDs)
        
        _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            operation.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume(returning: ())
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            db.add(operation)
        }
    }
        
    private func deleteRecordsInBatches(_ recordIDs: [CKRecord.ID], from database: CKDatabase) async throws {
        let batchSize = 400
        
        for chunk in recordIDs.chunked(into: batchSize) {
            let operation = CKModifyRecordsOperation(recordsToSave: nil, recordIDsToDelete: chunk)
            operation.isAtomic = false
            
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                operation.modifyRecordsResultBlock = { result in
                    switch result {
                    case .success:
                        continuation.resume(returning: ())
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
                database.add(operation)  // 指定されたデータベースを使用
            }
        }
    }
        
    
    
    func deleteMyDataFromCloudKit(groupID: String, userName: String) async throws {
        guard !groupID.isEmpty && !userName.isEmpty else {
            throw CKServiceError.invalidZone
        }
        
        try await deleteUserData(groupID: groupID, userName: userName)
    }

    func deleteUserData(groupID: String, userName: String) async throws {
        guard let memberID = try await findMember(groupID: groupID, userName: userName) else {
            return
        }
        
        let db = currentDatabase  // 現在のデータベースを使用
        let zoneID = currentZoneID
        
        let memberRecordID = CKRecord.ID(recordName: memberID, zoneID: zoneID)
        let memberRef = CKRecord.Reference(recordID: memberRecordID, action: .deleteSelf)
        
        let sessionQuery = CKQuery(recordType: RecordType.sessionRecord,
                                    predicate: NSPredicate(format: "memberRef == %@", memberRef))
        let sessions = try await performQuery(sessionQuery, in: db)
        
        var recordsToDelete: [CKRecord.ID] = []
        
        for session in sessions {
            let sessionRef = CKRecord.Reference(recordID: session.recordID, action: .deleteSelf)
            
            let taskQuery = CKQuery(recordType: RecordType.taskUsageSummary,
                                    predicate: NSPredicate(format: "sessionRef == %@", sessionRef))
            let tasks = try await performQuery(taskQuery, in: db)
            
            for task in tasks {
                let taskRef = CKRecord.Reference(recordID: task.recordID, action: .deleteSelf)
                
                let appQuery = CKQuery(recordType: RecordType.appUsage,
                                        predicate: NSPredicate(format: "taskRef == %@", taskRef))
                let apps = try await performQuery(appQuery, in: db)
            
                recordsToDelete.append(contentsOf: apps.map { $0.recordID })
                recordsToDelete.append(task.recordID)
            }
            recordsToDelete.append(session.recordID)
        }
        
        recordsToDelete.append(memberRecordID)
        
        if !recordsToDelete.isEmpty {
            try await deleteRecordsInBatches(recordsToDelete, from: db)  // データベースを渡す
        }
    }

    func deleteGroupIfOwner(groupID: String, ownerName: String, currentUserName: String) async throws -> Bool {
        guard ownerName == currentUserName else {
            return false
        }
        
        try await ensureZone()
        
        let db = currentDatabase  // 現在のデータベースを使用
        let zoneID = currentZoneID
        
        let groupRecordID = CKRecord.ID(recordName: groupID, zoneID: zoneID)
        let groupRef = CKRecord.Reference(recordID: groupRecordID, action: .deleteSelf)
        
        let memberQuery = CKQuery(recordType: RecordType.member, predicate: NSPredicate(format: "groupRef == %@", groupRef))
        let members = try await performQuery(memberQuery, in: db)
        
        var allRecordsToDelete: [CKRecord.ID] = []
        
        for member in members {
            let memberRef = CKRecord.Reference(recordID: member.recordID, action: .deleteSelf)
            
            let sessionQuery = CKQuery(recordType: RecordType.sessionRecord,
                                      predicate: NSPredicate(format: "memberRef == %@", memberRef))
            let sessions = try await performQuery(sessionQuery, in: db)
            
            for session in sessions {
                let sessionRef = CKRecord.Reference(recordID: session.recordID, action: .deleteSelf)
                
                let taskQuery = CKQuery(recordType: RecordType.taskUsageSummary,
                                       predicate: NSPredicate(format: "sessionRef == %@", sessionRef))
                let tasks = try await performQuery(taskQuery, in: db)
                
                for task in tasks {
                    let taskRef = CKRecord.Reference(recordID: task.recordID, action: .deleteSelf)
                    
                    let appQuery = CKQuery(recordType: RecordType.appUsage,
                                          predicate: NSPredicate(format: "taskRef == %@", taskRef))
                    let apps = try await performQuery(appQuery, in: db)
                    
                    allRecordsToDelete.append(contentsOf: apps.map { $0.recordID })
                    allRecordsToDelete.append(task.recordID)
                }
                allRecordsToDelete.append(session.recordID)
            }
            allRecordsToDelete.append(member.recordID)
        }
        
        let shareQuery = CKQuery(recordType: "cloudkit.share",
                               predicate: NSPredicate(format: "recordID == %@", groupRecordID))
        if let shares = try? await performQuery(shareQuery, in: db) {
            allRecordsToDelete.append(contentsOf: shares.map { $0.recordID })
        }
        
        allRecordsToDelete.append(groupRecordID)
        
        if !allRecordsToDelete.isEmpty {
            try await deleteRecordsInBatches(allRecordsToDelete, from: db)  // データベースを渡す
        }
        
        return true
    }

    func clearTemporaryStorage() {
        pendingUploads.removeAll()
        try? FileManager.default.removeItem(at: tempDataURL)
    }
    
    func getPendingUploadCount() -> Int {
        return pendingUploads.count
    }
    
    func forceSyncPendingData() async {
        if isOnline {
            await uploadPendingData()
        } else {
        }
    }
    
    func getNetworkStatus() -> String {
        return isOnline ? "Online" : "Offline"
    }
        
    func updateTaskCompletion(groupID: String, taskReminderId: String, isCompleted: Bool) async throws {
        guard !groupID.isEmpty && !taskReminderId.isEmpty else {
            throw CKServiceError.invalidZone
        }
        
        try await ensureZone()
        
        let predicate = NSPredicate(format: "reminderId == %@", taskReminderId)
        let query = CKQuery(recordType: RecordType.taskUsageSummary, predicate: predicate)
        
        let db = currentDatabase  // 現在のデータベースを使用
        let records = try await performQuery(query, in: db)
        
        guard !records.isEmpty else {
            return
        }
        
        var recordsToUpdate: [CKRecord] = []
        var sessionRecordsToUpdate: Set<CKRecord.ID> = []
        
        for record in records {
            record["isCompleted"] = isCompleted as CKRecordValue
            recordsToUpdate.append(record)
            
            if let sessionRef = record["sessionRef"] as? CKRecord.Reference {
                sessionRecordsToUpdate.insert(sessionRef.recordID)
            }
        }
        
        for sessionID in sessionRecordsToUpdate {
            if let sessionRecord = try? await db.record(for: sessionID) {
                let sessionRef = CKRecord.Reference(recordID: sessionID, action: .deleteSelf)
                let taskPredicate = NSPredicate(format: "sessionRef == %@", sessionRef)
                let taskQuery = CKQuery(recordType: RecordType.taskUsageSummary, predicate: taskPredicate)
                let tasks = try await performQuery(taskQuery, in: db)
                
                let completedCount = tasks.filter { ($0["isCompleted"] as? Bool) ?? false }.count
                sessionRecord["completedCount"] = completedCount as CKRecordValue
                recordsToUpdate.append(sessionRecord)
            }
        }
        
        if !recordsToUpdate.isEmpty {
            try await uploadRecordsInBatches(recordsToUpdate, to: db)  // データベースを渡す
        }
    }
        
    func updateTaskName(groupID: String, taskReminderId: String, newName: String) async throws {
        guard !groupID.isEmpty && !taskReminderId.isEmpty && !newName.isEmpty else {
            throw CKServiceError.invalidZone
        }
        
        try await ensureZone()
        
        let predicate = NSPredicate(format: "reminderId == %@", taskReminderId)
        let query = CKQuery(recordType: RecordType.taskUsageSummary, predicate: predicate)
        
        let db = currentDatabase  // 現在のデータベースを使用
        let records = try await performQuery(query, in: db)
        
        guard !records.isEmpty else {
            return
        }
        
        var recordsToUpdate: [CKRecord] = []
        for record in records {
            record["taskName"] = newName as CKRecordValue
            recordsToUpdate.append(record)
        }
        
        if !recordsToUpdate.isEmpty {
            try await uploadRecordsInBatches(recordsToUpdate, to: db)  // データベースを渡す
        }
    }
        
    func deleteTask(groupID: String, taskReminderId: String) async throws {
        guard !groupID.isEmpty && !taskReminderId.isEmpty else {
            throw CKServiceError.invalidZone
        }
        
        try await ensureZone()
        
        let predicate = NSPredicate(format: "reminderId == %@", taskReminderId)
        let query = CKQuery(recordType: RecordType.taskUsageSummary, predicate: predicate)
        
        let db = currentDatabase  // 現在のデータベースを使用
        let records = try await performQuery(query, in: db)
        
        let recordIDs = records.map { $0.recordID }
        
        if !recordIDs.isEmpty {
            try await deleteRecordsInBatches(recordIDs, from: db)  // データベースを渡す
        }
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

// MARK: - Future Implementation Ideas for Member Data Upload

/*
 共有データベースの制限により、メンバーが直接データをアップロードできない問題の解決案：
 
 1. プッシュ通知を使ったデータ収集
    - メンバーがデータを生成したら、オーナーにプッシュ通知を送信
    - オーナーのアプリがバックグラウンドで起動し、メンバーのデータを収集
 
 2. 一時的な公開レコードの使用
    - パブリックデータベースに一時的にデータを保存
    - オーナーが定期的にチェックして自分のプライベートデータベースに移動
 
 3. CloudKit以外の中間サービスの使用
    - Firebase等の別サービスを中継点として使用
    - メンバーがデータをアップロード後、オーナーが取得
 
 4. 定期的なデータ同期機能
    - オーナーが定期的にメンバーのローカルデータを要求
    - メンバーが承認したらデータを送信
*/
