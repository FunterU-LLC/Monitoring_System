// Note: このファイルはパブリックデータベースモードでは使用されません。
// 互換性のために残していますが、usePublicDatabase = true の場合は呼び出されません。

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
    @State private var showContent = false
    @State private var pulseAnimation = false
    
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 255/255, green: 204/255, blue: 102/255).opacity(0.15),
                    Color(red: 255/255, green: 224/255, blue: 153/255).opacity(0.05)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            
            VStack(spacing: 16) {
                HStack(spacing: 16) {
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
                            .frame(width: 50, height: 50)
                            .shadow(color: Color(red: 255/255, green: 204/255, blue: 102/255).opacity(0.3), radius: 10, x: 0, y: 3)
                            .scaleEffect(pulseAnimation ? 1.05 : 1.0)
                            .animation(
                                .easeInOut(duration: 2)
                                .repeatForever(autoreverses: true),
                                value: pulseAnimation
                            )
                        
                        Image(systemName: "person.3.fill")
                            .font(.system(size: 24))
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
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("グループへの招待")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
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

                        Text("以下のグループに参加しますか？")
                            .font(.system(size: 14))
                            .foregroundColor(colorScheme == .dark ? .white.opacity(0.8) : .secondary)
                    }
                    .opacity(showContent ? 1 : 0)
                    
                    Spacer()
                }

                if isLoadingInfo {
                    CompactLoadingCard()
                        .transition(.scale.combined(with: .opacity))
                } else {
                    CompactGroupInfoCard(
                        groupName: groupName,
                        ownerName: ownerName
                    )
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.9).combined(with: .opacity),
                        removal: .scale(scale: 1.1).combined(with: .opacity)
                    ))
                    .opacity(showContent ? 1 : 0)
                }
                
                if let error = errorMessage {
                    CompactErrorBanner(message: error)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                Spacer()

                HStack(spacing: 16) {
                    Button {
                        onFinish(false)
                    } label: {
                        Label("キャンセル", systemImage: "xmark")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(colorScheme == .dark ? .white.opacity(0.8) : .secondary)
                            .frame(minWidth: 100)
                            .padding(.vertical, 10)
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
                    .disabled(isJoining)
                    
                    Button {
                        joinGroup()
                    } label: {
                        ZStack {
                            if isJoining {
                                HStack(spacing: 6) {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle())
                                        .scaleEffect(0.7)
                                        .colorScheme(.light)
                                    Text("参加中...")
                                        .font(.system(size: 14, weight: .semibold))
                                }
                            } else {
                                Label("グループに参加", systemImage: "person.badge.plus")
                                    .font(.system(size: 14, weight: .semibold))
                            }
                        }
                        .foregroundColor(Color(red: 92/255, green: 64/255, blue: 51/255))
                        .frame(minWidth: 140)
                        .padding(.vertical, 10)
                        .background(
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color(red: 255/255, green: 204/255, blue: 102/255),
                                            Color(red: 255/255, green: 184/255, blue: 77/255)
                                        ],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .shadow(color: Color(red: 255/255, green: 204/255, blue: 102/255).opacity(0.3), radius: 8, x: 0, y: 3)
                        )
                }
                .buttonStyle(.plain)
                .disabled(isJoining || isLoadingInfo)
            }
            .opacity(showContent ? 1 : 0)
        }
        .padding(20)
        .frame(width: 500)
    }
    .onAppear {
        loadGroupInfo()
        withAnimation(.spring(response: 0.8, dampingFraction: 0.7)) {
            showContent = true
        }
        pulseAnimation = true
    }
}
    
    private func loadGroupInfo() {
        isLoadingInfo = true
        errorMessage = nil
        
        // まずシェアのタイトルから取得
        if let shareTitle = metadata.share[CKShare.SystemFieldKey.title] as? String {
            groupName = shareTitle
        }
        
        // オーナー名の取得
        if let shareOwnerName = metadata.share["ownerName"] as? String {
            ownerName = shareOwnerName
        } else {
            let ownerIdentity = metadata.ownerIdentity
            if let name = ownerIdentity.nameComponents?.formatted() {
                ownerName = name
            } else if let givenName = ownerIdentity.nameComponents?.givenName {
                ownerName = givenName
            } else {
                ownerName = "不明"
            }
        }
        
        // rootRecordが既に含まれている場合は、そこから情報を取得
        if let rootRecord = metadata.rootRecord {
            if let gName = rootRecord["groupName"] as? String {
                groupName = gName
            }
            if let oName = rootRecord["ownerName"] as? String {
                ownerName = oName
            }
        }
        
        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
            isLoadingInfo = false
        }
    }
    
    private func joinGroup() {
        isJoining = true
        errorMessage = nil
        
        Task {
            do {
                print("\n🎯 === Join Group Debug ===")
                print("📍 Metadata share zone: \(metadata.share.recordID.zoneID)")
                print("📍 Root record ID: \(metadata.hierarchicalRootRecordID?.recordName ?? "nil")")
                
                // 共有を受け入れる前の状態を確認
                await CloudKitService.shared.debugShareAndZoneInfo()
                
                try await CloudKitService.shared.acceptShare(from: metadata)
                
                print("✅ Share accepted successfully")
                
                // 共有を受け入れた後の状態を確認
                await CloudKitService.shared.debugShareAndZoneInfo()
                
                await MainActor.run {
                    onFinish(true)
                }
            } catch let error as CKError {
                print("❌ CKError: \(error)")
                print("  Error code: \(error.code)")
                print("  Error description: \(error.localizedDescription)")
                
                await MainActor.run {
                    withAnimation(.spring(response: 0.5)) {
                        isJoining = false
                        
                        switch error.code {
                        case .networkUnavailable, .networkFailure:
                            errorMessage = "ネットワークに接続できません"
                        case .notAuthenticated:
                            errorMessage = "iCloudにサインインしてください"
                        case .permissionFailure:
                            errorMessage = "参加権限がありません"
                        case .alreadyShared:
                            onFinish(true)
                            return
                        default:
                            errorMessage = "参加に失敗しました: \(error.localizedDescription)"
                        }
                    }
                }
            } catch {                
                await MainActor.run {
                    withAnimation(.spring(response: 0.5)) {
                        isJoining = false
                        errorMessage = "参加中にエラーが発生しました"
                    }
                }
            }
        }
    }
}

struct CompactLoadingCard: View {
    @State private var shimmer = false
    
    var body: some View {
        VStack(spacing: 12) {
            ForEach(0..<2) { _ in
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.gray.opacity(0.1))
                    .frame(height: 20)
                    .overlay(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0),
                                Color.white.opacity(0.3),
                                Color.white.opacity(0)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .offset(x: shimmer ? 200 : -200)
                    )
                    .clipped()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.gray.opacity(0.2), lineWidth: 1)
                )
        )
        .onAppear {
            withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                shimmer = true
            }
        }
    }
}

struct CompactGroupInfoCard: View {
    let groupName: String
    let ownerName: String
    
    var body: some View {
        HStack(spacing: 20) {
            ShareInfoRow(
                icon: "folder.fill",
                iconColor: Color(red: 255/255, green: 204/255, blue: 102/255),
                title: "グループ名",
                value: groupName
            )
            
            Divider()
                .frame(height: 40)
                .background(Color.gray.opacity(0.2))
            
            ShareInfoRow(
                icon: "person.fill",
                iconColor: Color(red: 255/255, green: 184/255, blue: 77/255),
                title: "オーナー",
                value: ownerName
            )
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color(red: 255/255, green: 204/255, blue: 102/255).opacity(0.3),
                                    Color(red: 255/255, green: 224/255, blue: 153/255).opacity(0.3)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
                .shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: 3)
        )
    }
}

struct CompactErrorBanner: View {
    @Environment(\.colorScheme) var colorScheme
    let message: String
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16))
                .foregroundColor(colorScheme == .dark ?
                    Color(red: 255/255, green: 99/255, blue: 71/255) : .red)
            
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(colorScheme == .dark ?
                    Color(red: 255/255, green: 99/255, blue: 71/255) : .red)
                .lineLimit(1)
            
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.red.opacity(colorScheme == .dark ? 0.2 : 0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.red.opacity(colorScheme == .dark ? 0.4 : 0.3), lineWidth: 1)
                )
        )
    }
}

struct ShareInfoRow: View {
    @Environment(\.colorScheme) var colorScheme
    let icon: String
    let iconColor: Color
    let title: String
    let value: String
    
    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(iconColor.opacity(colorScheme == .dark ? 0.2 : 0.1))
                    .frame(width: 36, height: 36)
                
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundColor(iconColor)
            }
            
            VStack(spacing: 2) {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundColor(colorScheme == .dark ? .white.opacity(0.7) : .secondary)
                
                Text(value)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(colorScheme == .dark ? .white : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
