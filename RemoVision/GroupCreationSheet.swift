import SwiftUI

struct GroupCreationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var ownerName  = ""
    @State private var groupName  = ""
    @State private var isCreating = false
    @State private var errorMsg:  String?
    @State private var showContent = false
    @State private var pulseAnimation = false
    
    // @FocusStateに変更
    @FocusState private var ownerFieldFocused: Bool
    @FocusState private var groupFieldFocused: Bool
    
    @AppStorage("currentGroupID") private var currentGroupID = ""
    @AppStorage("userName") private var userName = ""
    
    private var createButtonBackground: some View {
        let isActive = isFormValid && !isCreating
        let gradient = LinearGradient(
            colors: isActive ?
                [Color(red: 255/255, green: 204/255, blue: 102/255),
                 Color(red: 255/255, green: 184/255, blue: 77/255)] :
                [Color.gray, Color.gray.opacity(0.8)],
            startPoint: .leading,
            endPoint: .trailing
        )
        let shadowColor = isActive ?
            Color(red: 255/255, green: 204/255, blue: 102/255).opacity(0.3) :
            Color.clear
        
        return Capsule()
            .fill(gradient)
            .shadow(
                color: shadowColor,
                radius: 10,
                x: 0,
                y: 5
            )
    }
    
    private var ownerFieldBackground: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color.gray.opacity(0.1))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        ownerFieldFocused ?
                            Color(red: 255/255, green: 204/255, blue: 102/255).opacity(0.5) :
                            Color.gray.opacity(0.2),
                        lineWidth: 1.5
                    )
            )
    }
    
    private var groupFieldBackground: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color.gray.opacity(0.1))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        groupFieldFocused ?
                            Color(red: 255/255, green: 184/255, blue: 77/255).opacity(0.5) :
                            Color.gray.opacity(0.2),
                        lineWidth: 1.5
                    )
            )
    }

    var body: some View {
        ZStack {
            // Animated gradient background - オレンジ系に変更
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
                // Header with icon
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
                        
                        Image(systemName: "person.3.sequence.fill")
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
                        Text("新しいグループを作成")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [
                                        Color(red: 92/255, green: 64/255, blue: 51/255),
                                        Color(red: 92/255, green: 64/255, blue: 51/255).opacity(0.8)
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                        
                        Text("チームの作業を管理しましょう")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                    }
                    .opacity(showContent ? 1 : 0)
                    .offset(y: showContent ? 0 : 20)
                }
                
                // Input fields
                VStack(spacing: 16) {
                    // Owner name field
                    VStack(alignment: .leading, spacing: 8) {
                        Label("オーナー名", systemImage: "person.fill")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Color(red: 92/255, green: 64/255, blue: 51/255))
                        
                        TextField("あなたの名前", text: $ownerName)
                            .textFieldStyle(.plain)
                            .font(.system(size: 16))
                            .padding(12)
                            .background(ownerFieldBackground)
                            .onSubmit {
                                groupFieldFocused = true
                            }
                            .focused($ownerFieldFocused)
                    }
                    .opacity(showContent ? 1 : 0)
                    .offset(y: showContent ? 0 : 30)
                    
                    // Group name field
                    VStack(alignment: .leading, spacing: 8) {
                        Label("グループ名", systemImage: "folder.fill")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Color(red: 92/255, green: 64/255, blue: 51/255))
                        
                        TextField("グループの名前", text: $groupName)
                            .textFieldStyle(.plain)
                            .font(.system(size: 16))
                            .padding(12)
                            .background(groupFieldBackground)
                            .onSubmit {
                                if isFormValid {
                                    Task { await createGroup() }
                                }
                            }
                            .focused($groupFieldFocused)
                    }
                    .opacity(showContent ? 1 : 0)
                    .offset(y: showContent ? 0 : 30)
                }
                
                // Error message
                if let err = errorMsg {
                    ErrorMessage(message: err)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                
                Spacer()
                
                // Action buttons
                HStack(spacing: 16) {
                    Button {
                        withAnimation(.spring(response: 0.3)) {
                            dismiss()
                        }
                    } label: {
                        Text("キャンセル")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.secondary)
                            .frame(minWidth: 100)
                            .padding(.vertical, 12)
                            .background(
                                Capsule()
                                    .fill(Color.gray.opacity(0.1))
                                    .overlay(
                                        Capsule()
                                            .strokeBorder(Color.gray.opacity(0.3), lineWidth: 1)
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(isCreating)
                    
                    Button {
                        Task { await createGroup() }
                    } label: {
                        ZStack {
                            if isCreating {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle())
                                        .scaleEffect(0.8)
                                        .colorScheme(.dark)
                                    Text("作成中...")
                                        .font(.system(size: 15, weight: .semibold))
                                }
                            } else {
                                Label("グループを作成", systemImage: "plus.circle.fill")
                                    .font(.system(size: 15, weight: .semibold))
                            }
                        }
                        .foregroundColor(.white)
                        .frame(minWidth: 150)
                        .padding(.vertical, 12)
                        .background(createButtonBackground)
                    }
                    .buttonStyle(.plain)
                    .disabled(!isFormValid || isCreating)
                }
                .opacity(showContent ? 1 : 0)
                .offset(y: showContent ? 0 : 40)
                .animation(.spring(response: 0.6).delay(0.3), value: showContent)
            }
            .padding(32)
            .frame(width: 450)
        }
        .onAppear {
            withAnimation(.spring(response: 0.8, dampingFraction: 0.7)) {
                showContent = true
            }
            pulseAnimation = true
            
            // フォーカスを最初のフィールドに設定
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                ownerFieldFocused = true
            }
        }
    }
    
    private var isFormValid: Bool {
        !ownerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !isCreating
    }

    private func createGroup() async {
        // エラーメッセージをクリア
        withAnimation {
            errorMsg = nil
        }
        
        isCreating = true
        defer { isCreating = false }

        do {
            let result = try await CloudKitService.shared
                .createGroup(ownerName: ownerName,
                             groupName: groupName)

            presentShareSheet(url: result.url)

            DispatchQueue.main.async {
                GroupInfoStore.shared.groupInfo = GroupInfo(
                    groupName: groupName,
                    ownerName: ownerName,
                    recordID: result.groupID
                )
                currentGroupID = result.groupID
                userName = ownerName
                dismiss()
            }
        } catch {
            withAnimation(.spring(response: 0.5)) {
                errorMsg = error.localizedDescription
            }
        }
    }
    
    private func presentShareSheet(url: URL) {
        #if os(macOS)
        // クリップボードにコピー
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        
        // 成功通知
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let alert = NSAlert()
            alert.messageText = "共有URLをコピーしました"
            alert.informativeText = url.absoluteString.contains("icloud.com") ?
                "iCloudの共有URLがクリップボードにコピーされました。" :
                "グループ参加用のURLがクリップボードにコピーされました。"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
        #endif
    }
}

// Error message component
struct ErrorMessage: View {
    let message: String
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundColor(.red)
            
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(.red)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.red.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.red.opacity(0.3), lineWidth: 1)
                )
        )
    }
}
