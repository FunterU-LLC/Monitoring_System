import Foundation
import CloudKit
import SwiftData
import Network

@MainActor
final class CloudKitService {
    
    @Published var lastError: String? = nil

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
    }
    
    struct PortableAppUsage: Codable {
        let name: String
        let seconds: Double
    }

    private func ensureZone() async throws {
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
        case notImplemented
        case recordNotFound
        case invalidZone
        case userNotFound
        case groupNotFound
        case encodingError
        case memberNotFound
        case networkUnavailable
    }

    private struct RecordType {
        static let group = "Group"
        static let member = "Member"
        static let sessionRecord = "SessionRecord"
        static let taskUsageSummary = "TaskUsageSummary"
        static let appUsage = "AppUsage"
    }

    struct GroupRecord {
        let recordID: CKRecord.ID
        let groupName: String
        let ownerRecordID: CKRecord.ID
    }

    struct MemberRecord {
        let recordID: CKRecord.ID
        let userName: String
        let groupRef: CKRecord.Reference
    }

    func createGroup(ownerName: String,
                     groupName: String) async throws -> (url: URL, groupID: String) {

        try await ensureZone()
        let zoneID = Self.workZoneID

        let recordID = CKRecord.ID(recordName: UUID().uuidString, zoneID: zoneID)
        let groupRecord = CKRecord(recordType: "Group", recordID: recordID)
        groupRecord["groupName"] = groupName as CKRecordValue
        groupRecord["ownerName"] = ownerName as CKRecordValue

        let share = CKShare(rootRecord: groupRecord)
        share[CKShare.SystemFieldKey.title] = groupName as CKRecordValue
        share.publicPermission = .none

        let op = CKModifyRecordsOperation(
            recordsToSave: [groupRecord, share],
            recordIDsToDelete: nil)
        op.savePolicy = .ifServerRecordUnchanged
        op.isAtomic   = true

        return try await withCheckedThrowingContinuation { cont in
            op.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    // share.urlが実際のiCloud共有URL
                    if let shareURL = share.url {
                        #if DEBUG
                        print("✅ CKShare URL取得成功: \(shareURL)")
                        #endif
                        cont.resume(returning: (shareURL, groupRecord.recordID.recordName))
                    } else {
                        #if DEBUG
                        print("❌ CKShare URLが取得できません")
                        #endif
                        // フォールバック：一時的にカスタムURLを使用
                        let fallbackURL = URL(string: "monitoringsystem://share/\(groupRecord.recordID.recordName)")!
                        cont.resume(returning: (fallbackURL, groupRecord.recordID.recordName))
                    }

                case .failure(let error):
                    #if DEBUG
                    print("❌ グループ作成エラー: \(error)")
                    #endif
                    cont.resume(throwing: error)
                }
            }
            CKContainer.default().privateCloudDatabase.add(op)
        }
    }
    
    func acceptShare(from metadata: CKShare.Metadata) async throws {
        #if DEBUG
        print("===== acceptShare =====")
        print("Share ID: \(metadata.share.recordID)")
        print("Root Record ID: \(metadata.rootRecordID)")
        #endif
        
        return try await withCheckedThrowingContinuation { continuation in
            let operation = CKAcceptSharesOperation(shareMetadatas: [metadata])
            
            operation.perShareResultBlock = { metadata, result in
                #if DEBUG
                switch result {
                case .success(let share):
                    print("✅ 個別共有承認成功: \(share.recordID)")
                case .failure(let error):
                    print("❌ 個別共有承認エラー: \(error)")
                    
                    // オーナーエラーは無視
                    if let ckError = error as? CKError,
                       ckError.localizedDescription.contains("owner participant") {
                        print("ℹ️ オーナーによる承認試行 - 正常")
                    }
                }
                #endif
            }
            
            operation.acceptSharesResultBlock = { result in
                switch result {
                case .success:
                    #if DEBUG
                    print("✅ 共有承認操作完了")
                    #endif
                    continuation.resume(returning: ())
                    
                case .failure(let error):
                    #if DEBUG
                    print("❌ 共有承認操作失敗: \(error)")
                    #endif
                    
                    // 特定のエラーは成功として扱う
                    if let ckError = error as? CKError {
                        switch ckError.code {
                        case .alreadyShared:
                            #if DEBUG
                            print("ℹ️ すでに共有済み - 成功として扱う")
                            #endif
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

    func uploadSession(groupID: String, userName: String, sessionRecord: SessionRecordModel) async throws {
        
        let portableSession = convertToPortableSession(sessionRecord)
        
        if isOnline {
            try await uploadSessionDirectly(groupID: groupID, userName: userName, session: portableSession)
        } else {
            saveToTemporaryStorage(groupID: groupID, userName: userName, session: portableSession)
        }
    }
    
    private func convertToPortableSession(_ session: SessionRecordModel) -> PortableSessionRecord {
        let portableTasks = (session.taskSummaries ?? []).map { task in
            PortableTaskUsageSummary(
                reminderId: task.reminderId,
                taskName: task.taskName,
                isCompleted: task.isCompleted,
                startTime: task.startTime,
                endTime: task.endTime,
                totalSeconds: task.totalSeconds,
                comment: task.comment,
                appBreakdown: (task.appBreakdown ?? []).map { app in
                    PortableAppUsage(name: app.name, seconds: app.seconds)
                }
            )
        }
        
        return PortableSessionRecord(
            endTime: session.endTime,
            completedCount: session.completedCount,
            taskSummaries: portableTasks
        )
    }

    private func uploadSessionDirectly(groupID: String, userName: String, session: PortableSessionRecord) async throws {
        
        let memberID = try await createOrUpdateMember(groupID: groupID, userName: userName)
        let memberRecordID = CKRecord.ID(recordName: memberID, zoneID: Self.workZoneID)
        let memberRef = CKRecord.Reference(recordID: memberRecordID, action: .deleteSelf)
        
        var recordsToSave: [CKRecord] = []
        
        let sessionRecordID = CKRecord.ID(recordName: UUID().uuidString, zoneID: Self.workZoneID)
        let sessionRecord = CKRecord(recordType: RecordType.sessionRecord, recordID: sessionRecordID)
        sessionRecord["memberRef"] = memberRef as CKRecordValue
        sessionRecord["endTime"] = session.endTime as CKRecordValue
        sessionRecord["completedCount"] = session.completedCount as CKRecordValue
        recordsToSave.append(sessionRecord)
        
        let sessionRef = CKRecord.Reference(recordID: sessionRecordID, action: .deleteSelf)
        
        for task in session.taskSummaries {
            let taskRecordID = CKRecord.ID(recordName: UUID().uuidString, zoneID: Self.workZoneID)
            let taskRecord = CKRecord(recordType: RecordType.taskUsageSummary, recordID: taskRecordID)
            taskRecord["sessionRef"] = sessionRef as CKRecordValue
            taskRecord["reminderId"] = task.reminderId as CKRecordValue
            taskRecord["taskName"] = task.taskName as CKRecordValue
            taskRecord["isCompleted"] = task.isCompleted as CKRecordValue
            taskRecord["startTime"] = task.startTime as CKRecordValue
            taskRecord["endTime"] = task.endTime as CKRecordValue
            taskRecord["totalSeconds"] = task.totalSeconds as CKRecordValue
            if let comment = task.comment {
                taskRecord["comment"] = comment as CKRecordValue
            }
            recordsToSave.append(taskRecord)
            
            let taskRef = CKRecord.Reference(recordID: taskRecordID, action: .deleteSelf)
            
            for app in task.appBreakdown {
                let appRecordID = CKRecord.ID(recordName: UUID().uuidString, zoneID: Self.workZoneID)
                let appRecord = CKRecord(recordType: RecordType.appUsage, recordID: appRecordID)
                appRecord["taskRef"] = taskRef as CKRecordValue
                appRecord["name"] = app.name as CKRecordValue
                appRecord["seconds"] = app.seconds as CKRecordValue
                recordsToSave.append(appRecord)
            }
        }
        
        try await uploadRecordsInBatches(recordsToSave)
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
    
    func createOrUpdateMember(groupID: String, userName: String) async throws -> String {
        try await ensureZone()
        
        let groupRecordID = CKRecord.ID(recordName: groupID, zoneID: Self.workZoneID)
        let groupRef = CKRecord.Reference(recordID: groupRecordID, action: .deleteSelf)
        
        if let existingMemberID = try await findMember(groupID: groupID, userName: userName) {
            return existingMemberID
        }
        
        let memberRecordID = CKRecord.ID(recordName: UUID().uuidString, zoneID: Self.workZoneID)
        let memberRecord = CKRecord(recordType: RecordType.member, recordID: memberRecordID)
        memberRecord["userName"] = userName as CKRecordValue
        memberRecord["groupRef"] = groupRef as CKRecordValue
        
        let db = CKContainer.default().privateCloudDatabase
        
        return try await withCheckedThrowingContinuation { continuation in
            db.save(memberRecord) { record, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let record = record {
                    continuation.resume(returning: record.recordID.recordName)
                } else {
                    continuation.resume(throwing: CKServiceError.recordNotFound)
                }
            }
        }
    }
    
    private func findMember(groupID: String, userName: String) async throws -> String? {
        let groupRecordID = CKRecord.ID(recordName: groupID, zoneID: Self.workZoneID)
        let groupRef = CKRecord.Reference(recordID: groupRecordID, action: .deleteSelf)
        
        let predicate = NSPredicate(format: "groupRef == %@ AND userName == %@", groupRef, userName)
        let query = CKQuery(recordType: RecordType.member, predicate: predicate)
        
        let db = CKContainer.default().privateCloudDatabase
        
        return try await withCheckedThrowingContinuation { continuation in
            db.fetch(withQuery: query, inZoneWith: Self.workZoneID, desiredKeys: nil, resultsLimit: 1000) { result in
                switch result {
                case .success(let (matchResults, _)):
                    let records = matchResults.compactMap { (recordID, recordResult) in
                        if case .success(let record) = recordResult {
                            return record
                        }
                        return nil
                    }
                    if let first = records.first {
                        continuation.resume(returning: first.recordID.recordName)
                    } else {
                        continuation.resume(returning: nil)
                    }
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    private func uploadRecordsInBatches(_ records: [CKRecord]) async throws {
        let batchSize = 400
        let db = CKContainer.default().privateCloudDatabase
        
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
                
                db.add(operation)
            }
        }
    }

    func fetchGroupMembers(groupID: String) async throws -> [String] {
        
        guard !groupID.isEmpty else {
            return []
        }
        
        try await ensureZone()
        
        let groupRecordID = CKRecord.ID(recordName: groupID, zoneID: Self.workZoneID)
        let groupRef = CKRecord.Reference(recordID: groupRecordID, action: .deleteSelf)
        
        let memberPredicate = NSPredicate(format: "groupRef == %@", groupRef)
        let memberQuery = CKQuery(recordType: RecordType.member, predicate: memberPredicate)
        memberQuery.sortDescriptors = [NSSortDescriptor(key: "userName", ascending: true)]
        
        let db = CKContainer.default().privateCloudDatabase
        let memberRecords = try await performQuery(memberQuery, in: db)
        
        let memberNames = memberRecords.compactMap { record in
            record["userName"] as? String
        }
        
        return memberNames
    }
    
    func fetchUserSummaries(groupID: String, userName: String, forDays days: Int) async throws -> ([TaskUsageSummary], Int) {
        
        guard !groupID.isEmpty && !userName.isEmpty else {
            return ([], 0)
        }
        
        try await ensureZone()
        
        guard let memberID = try await findMember(groupID: groupID, userName: userName) else {
            return ([], 0)
        }
        
        let memberRecordID = CKRecord.ID(recordName: memberID, zoneID: Self.workZoneID)
        let memberRef = CKRecord.Reference(recordID: memberRecordID, action: .deleteSelf)
        
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let fromDate = calendar.date(byAdding: .day, value: -(days - 1), to: startOfToday)!
        
        let sessionPredicate = NSPredicate(format: "memberRef == %@ AND endTime >= %@", memberRef, fromDate as NSDate)
        let sessionQuery = CKQuery(recordType: RecordType.sessionRecord, predicate: sessionPredicate)
        sessionQuery.sortDescriptors = [NSSortDescriptor(key: "endTime", ascending: false)]
        
        let db = CKContainer.default().privateCloudDatabase
        let sessionRecords = try await performQuery(sessionQuery, in: db)
        
        var merged: [String: TaskUsageSummary] = [:]
        var totalCompleted = 0
        
        for sessionRecord in sessionRecords {
            
            let sessionRef = CKRecord.Reference(recordID: sessionRecord.recordID, action: .deleteSelf)
            let taskSummaries = try await fetchTaskSummariesForManagement(sessionRef: sessionRef)
            
            let sessionCompletedCount = taskSummaries.filter { $0.isCompleted }.count
            totalCompleted += sessionCompletedCount
            
            
            for task in taskSummaries {
                let key = task.reminderId.isEmpty ? task.taskName : task.reminderId
                
                if var existing = merged[key] {
                    existing.totalSeconds += task.totalSeconds
                    existing.appBreakdown = mergeAppUsage(existing.appBreakdown, task.appBreakdown)
                    existing.isCompleted = existing.isCompleted || task.isCompleted
                    
                    if existing.comment?.isEmpty ?? true, let newComment = task.comment, !newComment.isEmpty {
                        existing.comment = newComment
                    }
                    
                    existing.endTime = max(existing.endTime, task.endTime)
                    existing.startTime = min(existing.startTime, task.startTime)
                    
                    merged[key] = existing
                } else {
                    merged[key] = task
                }
            }
        }
        
        let mergedCompletedCount = merged.values.filter { $0.isCompleted }.count
        
        let sortedTasks = Array(merged.values).sorted { $0.totalSeconds > $1.totalSeconds }
        return (sortedTasks, mergedCompletedCount)
    }
    
    private func fetchTaskSummariesForManagement(sessionRef: CKRecord.Reference) async throws -> [TaskUsageSummary] {
        let taskPredicate = NSPredicate(format: "sessionRef == %@", sessionRef)
        let taskQuery = CKQuery(recordType: RecordType.taskUsageSummary, predicate: taskPredicate)
        
        let db = CKContainer.default().privateCloudDatabase
        let taskRecords = try await performQuery(taskQuery, in: db)
        
        var tasks: [TaskUsageSummary] = []
        
        for taskRecord in taskRecords {
            guard let reminderId = taskRecord["reminderId"] as? String,
                  let taskName = taskRecord["taskName"] as? String,
                  let isCompleted = taskRecord["isCompleted"] as? Bool,
                  let startTime = taskRecord["startTime"] as? Date,
                  let endTime = taskRecord["endTime"] as? Date,
                  let totalSeconds = taskRecord["totalSeconds"] as? Double else { continue }
            
            let comment = taskRecord["comment"] as? String
            
            let taskRef = CKRecord.Reference(recordID: taskRecord.recordID, action: .deleteSelf)
            let appUsages = try await fetchAppUsagesForManagement(taskRef: taskRef)
            
            let task = TaskUsageSummary(
                reminderId: reminderId,
                taskName: taskName,
                isCompleted: isCompleted,
                startTime: startTime,
                endTime: endTime,
                totalSeconds: totalSeconds,
                comment: comment,
                appBreakdown: appUsages
            )
            tasks.append(task)
        }
        
        return tasks
    }
    
    private func fetchAppUsagesForManagement(taskRef: CKRecord.Reference) async throws -> [AppUsage] {
        let appPredicate = NSPredicate(format: "taskRef == %@", taskRef)
        let appQuery = CKQuery(recordType: RecordType.appUsage, predicate: appPredicate)
        
        let db = CKContainer.default().privateCloudDatabase
        let appRecords = try await performQuery(appQuery, in: db)
        
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
            
            let taskRef = CKRecord.Reference(recordID: taskRecord.recordID, action: .deleteSelf)
            let appUsages = try await fetchAppUsages(taskRef: taskRef)
            
            let task = PortableTaskUsageSummary(reminderId: reminderId,
                                              taskName: taskName,
                                              isCompleted: isCompleted,
                                              startTime: startTime,
                                              endTime: endTime,
                                              totalSeconds: totalSeconds,
                                              comment: comment,
                                              appBreakdown: appUsages)
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
        return try await withCheckedThrowingContinuation { continuation in
            database.fetch(withQuery: query, inZoneWith: Self.workZoneID, desiredKeys: nil, resultsLimit: 1000) { result in
                switch result {
                case .success(let (matchResults, _)):
                    let records = matchResults.compactMap { (recordID, recordResult) in
                        if case .success(let record) = recordResult {
                            return record
                        }
                        return nil
                    }
                    continuation.resume(returning: records)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func initializeCloudKitSchema() async throws {
        try await ensureZone()
        
        let sampleGroupID = UUID().uuidString
        let sampleUserName = "SchemaInitUser"
        
        try await createSampleMember(groupID: sampleGroupID, userName: sampleUserName)
        
        try await createSampleSession(groupID: sampleGroupID, userName: sampleUserName)
    }

    func setupCloudKitAndSyncPendingData() async throws {
        
        try await initializeCloudKitSchema()
        
        if isOnline {
            await uploadPendingData()
        } else {
        }
    }

    private func createSampleMember(groupID: String, userName: String) async throws {
        let groupRecordID = CKRecord.ID(recordName: groupID, zoneID: Self.workZoneID)
        let groupRef = CKRecord.Reference(recordID: groupRecordID, action: .deleteSelf)
        
        let memberRecordID = CKRecord.ID(recordName: "SAMPLE_MEMBER", zoneID: Self.workZoneID)
        let memberRecord = CKRecord(recordType: RecordType.member, recordID: memberRecordID)
        memberRecord["userName"] = userName as CKRecordValue
        memberRecord["groupRef"] = groupRef as CKRecordValue
        
        let db = CKContainer.default().privateCloudDatabase
        
        _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CKRecord, Error>) in
            db.save(memberRecord) { record, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let record = record {
                    continuation.resume(returning: record)
                } else {
                    continuation.resume(throwing: CKServiceError.recordNotFound)
                }
            }
        }
    }

    private func createSampleSession(groupID: String, userName: String) async throws {
        let memberID = try await createOrUpdateMember(groupID: groupID, userName: userName)
        let memberRecordID = CKRecord.ID(recordName: memberID, zoneID: Self.workZoneID)
        let memberRef = CKRecord.Reference(recordID: memberRecordID, action: .deleteSelf)
        
        var recordsToSave: [CKRecord] = []
        
        let sessionRecordID = CKRecord.ID(recordName: "SAMPLE_SESSION", zoneID: Self.workZoneID)
        let sessionRecord = CKRecord(recordType: RecordType.sessionRecord, recordID: sessionRecordID)
        sessionRecord["memberRef"] = memberRef as CKRecordValue
        sessionRecord["endTime"] = Date() as CKRecordValue
        sessionRecord["completedCount"] = 0 as CKRecordValue
        recordsToSave.append(sessionRecord)
        
        let sessionRef = CKRecord.Reference(recordID: sessionRecordID, action: .deleteSelf)
        
        let taskRecordID = CKRecord.ID(recordName: "SAMPLE_TASK", zoneID: Self.workZoneID)
        let taskRecord = CKRecord(recordType: RecordType.taskUsageSummary, recordID: taskRecordID)
        taskRecord["sessionRef"] = sessionRef as CKRecordValue
        taskRecord["reminderId"] = "sample" as CKRecordValue
        taskRecord["taskName"] = "Sample Task" as CKRecordValue
        taskRecord["isCompleted"] = false as CKRecordValue
        taskRecord["startTime"] = Date() as CKRecordValue
        taskRecord["endTime"] = Date() as CKRecordValue
        taskRecord["totalSeconds"] = 0.0 as CKRecordValue
        recordsToSave.append(taskRecord)
        
        let taskRef = CKRecord.Reference(recordID: taskRecordID, action: .deleteSelf)
        
        let appRecordID = CKRecord.ID(recordName: "SAMPLE_APP", zoneID: Self.workZoneID)
        let appRecord = CKRecord(recordType: RecordType.appUsage, recordID: appRecordID)
        appRecord["taskRef"] = taskRef as CKRecordValue
        appRecord["name"] = "Sample App" as CKRecordValue
        appRecord["seconds"] = 0.0 as CKRecordValue
        recordsToSave.append(appRecord)
        
        try await uploadRecordsInBatches(recordsToSave)
        
        let recordIDsToDelete = recordsToSave.map { $0.recordID }
        try await deleteRecords(recordIDsToDelete)
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
    
    func deleteAllCloudKitData() async throws {
        
        let db = CKContainer.default().privateCloudDatabase
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let operation = CKModifyRecordZonesOperation(recordZonesToSave: nil,
                                                        recordZoneIDsToDelete: [Self.workZoneID])
            operation.modifyRecordZonesResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume(returning: ())
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            db.add(operation)
        }
        
        try await ensureZone()
    }
        
    private func deleteAllRecordsOfType(_ recordType: String) async throws {
        let db = CKContainer.default().privateCloudDatabase
        
        let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
        
        do {
            let records = try await performQuery(query, in: db)
            
            guard !records.isEmpty else {
                return
            }
            
            let recordIDs = records.map { $0.recordID }
            
            try await deleteRecordsInBatches(recordIDs)
        } catch {
            throw CKServiceError.encodingError
        }
    }
        
    private func deleteRecordsInBatches(_ recordIDs: [CKRecord.ID]) async throws {
        let batchSize = 400
        let db = CKContainer.default().privateCloudDatabase
            
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
                db.add(operation)
            }
        }
    }
        
    func deleteUserData(groupID: String, userName: String) async throws {
            
        guard let memberID = try await findMember(groupID: groupID, userName: userName) else {
            return
        }
            
        let memberRecordID = CKRecord.ID(recordName: memberID, zoneID: Self.workZoneID)
        let memberRef = CKRecord.Reference(recordID: memberRecordID, action: .deleteSelf)
            
        let sessionQuery = CKQuery(recordType: RecordType.sessionRecord,
                                    predicate: NSPredicate(format: "memberRef == %@", memberRef))
        let db = CKContainer.default().privateCloudDatabase
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
            try await deleteRecordsInBatches(recordsToDelete)
        } else {
        }
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
            
        let db = CKContainer.default().privateCloudDatabase
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
            try await uploadRecordsInBatches(recordsToUpdate)
        } else {
        }
    }
        
    func updateTaskName(groupID: String, taskReminderId: String, newName: String) async throws {
        
        guard !groupID.isEmpty && !taskReminderId.isEmpty && !newName.isEmpty else {
            throw CKServiceError.invalidZone
        }
            
        try await ensureZone()
        
        let predicate = NSPredicate(format: "reminderId == %@", taskReminderId)
        let query = CKQuery(recordType: RecordType.taskUsageSummary, predicate: predicate)
        
        let db = CKContainer.default().privateCloudDatabase
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
            try await uploadRecordsInBatches(recordsToUpdate)
        } else {
        }
    }
        
    func deleteTask(groupID: String, taskReminderId: String) async throws {
        
        guard !groupID.isEmpty && !taskReminderId.isEmpty else {
            throw CKServiceError.invalidZone
        }
        
        try await ensureZone()
        
        let predicate = NSPredicate(format: "reminderId == %@", taskReminderId)
        let query = CKQuery(recordType: RecordType.taskUsageSummary, predicate: predicate)
        
        let db = CKContainer.default().privateCloudDatabase
        let records = try await performQuery(query, in: db)
        
        let recordIDs = records.map { $0.recordID }
        
        if !recordIDs.isEmpty {
            try await deleteRecordsInBatches(recordIDs)
        } else {
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
