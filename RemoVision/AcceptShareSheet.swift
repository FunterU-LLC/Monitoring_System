import SwiftUI
import CloudKit

struct AcceptShareSheet: View {

    let metadata: CKShare.Metadata
    var onFinish: (Bool) -> Void

    @State private var isJoining = false
    @State private var errorMessage: String? = nil
    @State private var groupName: String = "読み込み中..."
    @State private var ownerName: String = "読み込み中..."
    @State private var isLoadingInfo = true

    var body: some View {
        VStack(spacing: 24) {
            // タイトル
            HStack {
                Image(systemName: "person.3.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.blue, .purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                
                Text("グループに参加")
                    .font(.title2.bold())
            }

            // グループ情報
            if isLoadingInfo {
                ProgressView("グループ情報を取得中...")
                    .progressViewStyle(CircularProgressViewStyle())
                    .scaleEffect(0.8)
                    .frame(height: 60)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("グループ名", systemImage: "folder.fill")
                            .foregroundColor(.secondary)
                            .frame(width: 100, alignment: .leading)
                        Text(groupName)
                            .font(.system(size: 16, weight: .semibold))
                    }
                    
                    HStack {
                        Label("オーナー", systemImage: "person.fill")
                            .foregroundColor(.secondary)
                            .frame(width: 100, alignment: .leading)
                        Text(ownerName)
                    }
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.gray.opacity(0.1))
                )
            }

            // エラーメッセージ
            if let error = errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                    .font(.caption)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.red.opacity(0.1))
                    )
            }

            // ボタン
            HStack(spacing: 16) {
                Button("キャンセル") {
                    onFinish(false)
                }
                .buttonStyle(.bordered)
                .disabled(isJoining)
                
                Button {
                    joinGroup()
                } label: {
                    HStack {
                        if isJoining {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle())
                                .scaleEffect(0.8)
                                .frame(width: 16, height: 16)
                        } else {
                            Image(systemName: "person.badge.plus")
                        }
                        Text("参加")
                    }
                }
                .disabled(isJoining || isLoadingInfo)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
        .frame(width: 450)
        .onAppear {
            loadGroupInfo()
        }
    }
    
    private func loadGroupInfo() {
        isLoadingInfo = true
        errorMessage = nil
        
        // メタデータから直接情報を取得
        if let shareTitle = metadata.share[CKShare.SystemFieldKey.title] as? String {
            groupName = shareTitle
        }
        
        // オーナー情報（ownerIdentityは非Optional）
        let ownerIdentity = metadata.ownerIdentity
        if let name = ownerIdentity.nameComponents?.formatted() {
            ownerName = name
        } else if let givenName = ownerIdentity.nameComponents?.givenName {
            ownerName = givenName
        } else {
            ownerName = "不明"
        }
        
        // rootRecordから追加情報を取得する試み
        Task {
            do {
                // 注意: 承認前はrootRecordにアクセスできない可能性がある
                if let rootRecord = metadata.rootRecord {
                    if let gName = rootRecord["groupName"] as? String {
                        await MainActor.run {
                            groupName = gName
                        }
                    }
                    if let oName = rootRecord["ownerName"] as? String {
                        await MainActor.run {
                            ownerName = oName
                        }
                    }
                }
            } catch {
                #if DEBUG
                print("⚠️ rootRecord取得エラー（承認前は正常）: \(error)")
                #endif
            }
            
            await MainActor.run {
                isLoadingInfo = false
            }
        }
    }
    
    private func joinGroup() {
        isJoining = true
        errorMessage = nil
        
        Task {
            do {
                #if DEBUG
                print("📤 共有を承認中...")
                #endif
                
                try await CloudKitService.shared.acceptShare(from: metadata)
                
                #if DEBUG
                print("✅ 共有承認成功")
                #endif
                
                await MainActor.run {
                    onFinish(true)
                }
            } catch let error as CKError {
                #if DEBUG
                print("❌ CKError: \(error.code) - \(error.localizedDescription)")
                #endif
                
                await MainActor.run {
                    isJoining = false
                    
                    switch error.code {
                    case .networkUnavailable, .networkFailure:
                        errorMessage = "ネットワークに接続できません"
                    case .notAuthenticated:
                        errorMessage = "iCloudにサインインしてください"
                    case .permissionFailure:
                        errorMessage = "参加権限がありません"
                    case .alreadyShared:
                        // すでに参加している場合は成功として扱う
                        onFinish(true)
                        return
                    default:
                        errorMessage = "参加に失敗しました: \(error.localizedDescription)"
                    }
                }
            } catch {
                #if DEBUG
                print("❌ 予期しないエラー: \(error)")
                #endif
                
                await MainActor.run {
                    isJoining = false
                    errorMessage = "参加中にエラーが発生しました"
                }
            }
        }
    }
}
