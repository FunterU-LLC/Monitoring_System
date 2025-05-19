import Foundation
import CloudKit

@MainActor
final class CloudKitService {

    static let shared = CloudKitService()
    static let workZoneID = CKRecordZone.ID(zoneName: "WorkGroupZone", ownerName: CKCurrentUserDefaultName)
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

    struct WorkRecord {
        let recordID: CKRecord.ID
        let memberRef: CKRecord.Reference
        let start: Date
        let end: Date
        let jsonBlob: Data
    }

    func createGroup(ownerName: String,
                     groupName: String) async throws -> (url: URL, groupID: String) {

        print("🛠️ CloudKitService.createGroup – start")
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
                    if share.url != nil {
                        let recordName = groupRecord.recordID.recordName
                        let customURL = URL(string: "monitoringsystem://share/\(recordName)")!
                        
                        cont.resume(returning: (customURL, groupRecord.recordID.recordName))
                    } else {
                        cont.resume(throwing: CKServiceError.notImplemented)
                    }

                case .failure(let error):
                    if let ckErr = error as? CKError {
                        print("CKError: \(ckErr.code.rawValue) – \(ckErr.code)")

                        if let partial =
                            ckErr.userInfo[CKPartialErrorsByItemIDKey] as? [CKRecord.ID : Error] {

                            for (id, subError) in partial {
                                print("• \(id.recordName) → \(subError.localizedDescription)")
                            }
                        }
                    }
                    cont.resume(throwing: error)
                }
            }
            CKContainer.default().privateCloudDatabase.add(op)
        }
    }
    
    
    func acceptShare(from metadata: CKShare.Metadata) async throws {
        print("🌩 CloudKitService: Accepting share for \(metadata.share.recordID.recordName)")
        
        return try await withCheckedThrowingContinuation { continuation in
            let operation = CKAcceptSharesOperation(shareMetadatas: [metadata])
            
            operation.perShareResultBlock = { metadata, result in
                switch result {
                case .success(let share):
                    print("✅ Share accepted: \(share.recordID.recordName)")
                case .failure(let error):
                    print("❌ Error accepting individual share: \(error.localizedDescription)")
                }
            }
            
            operation.acceptSharesResultBlock = { result in
                switch result {
                case .success:
                    print("✅ Accept shares operation completed successfully")
                    continuation.resume(returning: ())
                case .failure(let error):
                    print("❌ Overall operation failed: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                }
            }
            
            CKContainer.default().add(operation)
        }
    }

    func upload(workRecord: WorkRecord) async throws {
        throw CKServiceError.notImplemented
    }

    func fetchWorkRecords() async throws -> [WorkRecord] {
        throw CKServiceError.notImplemented
    }
}
