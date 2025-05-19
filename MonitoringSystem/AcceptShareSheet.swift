import SwiftUI
import CloudKit

struct AcceptShareSheet: View {

    let metadata: CKShare.Metadata
    var onFinish: (Bool) -> Void

    @State private var isJoining = false

    var body: some View {
        VStack(spacing: 24) {
            Text("グループに参加")
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 6) {
                Text("グループ名: \(metadata.rootRecord?.value(forKey: "groupName") as? String ?? "不明")")
                Text("オーナー: \(metadata.ownerIdentity.nameComponents?.givenName ?? "不明")")
            }

            HStack {
                Button("キャンセル") { onFinish(false) }
                Spacer()
                Button("参加") {
                    print("✅ Join button tapped")
                    isJoining = true
                    
                    Task {
                        do {
                            try await CloudKitService.shared.acceptShare(from: metadata)
                            print("✅ Successfully joined the share")
                            onFinish(true)
                        } catch {
                            print("❌ Failed to join share: \(error.localizedDescription)")
                            isJoining = false
                            onFinish(false)
                        }
                    }
                }
                .disabled(isJoining)
                .buttonStyle(.borderedProminent)
                .disabled(isJoining)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
        .frame(width: 420)
    }
}
