import SwiftUI
import AppKit
import ObjectiveC.runtime
import CloudKit

enum MainButtonFocus: Int, CaseIterable {
    case additionalReport
    case start
    case management
    case cameraTest
    
    func left() -> MainButtonFocus {
        let newIndex = max(0, rawValue - 1)
        return MainButtonFocus(rawValue: newIndex) ?? .additionalReport
    }
    
    func right() -> MainButtonFocus {
        let newIndex = min(MainButtonFocus.allCases.count - 1, rawValue + 1)
        return MainButtonFocus(rawValue: newIndex) ?? .cameraTest
    }
}

struct KeyboardMonitorView: NSViewRepresentable {
    var onKeyDown: (NSEvent) -> Void
    
    func makeNSView(context: Context) -> NSView {
        let view = KeyboardHandlingNSView()
        view.onKeyDown = onKeyDown
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        
    }
    
    class KeyboardHandlingNSView: NSView {
        var onKeyDown: ((NSEvent) -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.makeFirstResponder(self)
        }
        override func keyDown(with event: NSEvent) {
            if let responder = window?.firstResponder, responder is NSTextView {
                super.keyDown(with: event)
            } else {
                onKeyDown?(event)
            }
        }
    }

}

struct FocusableButtonStyle: ButtonStyle {
    let isFocused: Bool
    let isEnabled: Bool
    
    func makeBody(configuration: Configuration) -> some View {
        let bgColor: Color = {
            if !isEnabled {
                return Color(nsColor: .controlBackgroundColor).opacity(0.3)
            } else if isFocused {
                return Color.accentColor
            } else {
                return Color(nsColor: .controlBackgroundColor)
            }
        }()
        
        let fgColor: Color = {
            if !isEnabled {
                return Color.secondary
            } else if isFocused {
                return Color.white
            } else {
                return Color.primary
            }
        }()
        
        return configuration.label
            .padding()
            .frame(minWidth: 140, minHeight: 50)
            .background(bgColor)
            .foregroundColor(fgColor)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    .allowsHitTesting(false)
            )
            .shadow(color: isFocused ? .black.opacity(0.4) : .clear,
                    radius: 4, x: 0, y: 2)
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.9 : 1.0)
            .onHover { inside in
                if inside && isEnabled {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
    }
}

struct HoverPressButtonStyle: ButtonStyle {
    var overrideIsPressed: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .scaleEffect((configuration.isPressed || overrideIsPressed) ? 0.9 : 1.0)
            .animation(.easeInOut(duration: 0.1),
                       value: (configuration.isPressed || overrideIsPressed))
            .onHover { hovering in
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
    }
}


struct ContentView: View {
    
    @State private var focusedButton: MainButtonFocus = .start
    
    @ObservedObject var groupInfoStore = GroupInfoStore.shared
    @State private var showGroupDetail = false
    
    @Environment(PopupCoordinator.self) var popupCoordinator
    @Environment(RemindersManager.self) var remindersManager
    @Environment(AppUsageManager.self) var appUsageManager
    @Environment(FaceRecognitionManager.self) var faceRecognitionManager
    @Environment(PermissionCoordinator.self) var permissionCoordinator
    @Bindable var bindableCoordinator: PopupCoordinator
    @State private var showManagement = false
    @State private var showCameraTestTab = false
    @State private var showPermissionGate = false
    @State private var parentWindowSize: CGSize = .zero
    
    @AppStorage("currentGroupID") private var currentGroupID: String = ""
    @AppStorage("userName") private var userName: String = ""
    
    @State private var showOnboarding = false
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
        
    init(bindableCoordinator: PopupCoordinator) {
        self.bindableCoordinator = bindableCoordinator
    }
    
    var body: some View {
        GeometryReader { geo in
            ZStack {
                VStack {
                    Spacer()
                    Button("作業開始") {
                        popupCoordinator.showTaskStartPopup = true
                    }
                    .disabled(false)
                    .buttonStyle(FocusableButtonStyle(
                        isFocused: (focusedButton == .start),
                        isEnabled: true
                    ))
                    .onHover { inside in
                        if inside {
                            focusedButton = .start
                        }
                    }
                    .font(.title)
                    
                    Spacer()
                    
                    HStack {
                        Spacer()
                        
                        Button("マネジメント") {
                            openManagement()
                        }
                        .disabled(false)
                        .buttonStyle(FocusableButtonStyle(
                            isFocused: (focusedButton == .management),
                            isEnabled: true
                        ))
                        .onHover { inside in
                            if inside {
                                focusedButton = .management
                            }
                        }
                        
                        Button("カメラテスト") {
                            showCameraTestTab = true
                        }
                        .disabled(false)
                        .buttonStyle(FocusableButtonStyle(
                            isFocused: (focusedButton == .cameraTest),
                            isEnabled: true
                        ))
                        .onHover { inside in
                            if inside {
                                focusedButton = .cameraTest
                            }
                        }
                    }
                    Spacer().frame(height: 12)
                }
            }
            .overlay(WindowMinSizeEnforcer(minWidth: 800, minHeight: 600)
                     .allowsHitTesting(false))
            .frame(width: geo.size.width, height: geo.size.height)
            .overlay(
                KeyboardMonitorView { event in
                    handleKeyDown(event)
                }
                .allowsHitTesting(false)
            )
            .onAppear {
                parentWindowSize = geo.size
            }
            .task {
                showOnboarding = true
                
                // GroupIDはあるがGroupInfoがない場合、CloudKitから再取得を試みる
                if !currentGroupID.isEmpty && groupInfoStore.groupInfo == nil {
                    #if DEBUG
                    print("⚠️ GroupIDはあるがGroupInfoがない。CloudKitから再取得を試みます...")
                    #endif
                    
                    await fetchGroupInfoFromCloudKit(groupID: currentGroupID)
                }
            }
            .onChange(of: geo.size) { _, newSize in
                parentWindowSize = newSize
            }
        }
        .sheet(isPresented: $bindableCoordinator.showTaskStartPopup) {
            TaskStartPopupView(
                remindersManager: _remindersManager,
                appUsageManager: _appUsageManager,
                popupCoordinator: _popupCoordinator,
                faceRecognitionManager: _faceRecognitionManager
            )
        }
        .sheet(isPresented: $showManagement) {
            let targetWidth  = min(max(parentWindowSize.width, 400), 900)
            let targetHeight = max(parentWindowSize.height, 600)
            
            ManagementView(appUsageManager: _appUsageManager)
                .frame(minWidth:  targetWidth,
                       idealWidth: targetWidth,
                       maxWidth:   targetWidth,
                       minHeight:  targetHeight,
                       idealHeight: targetHeight,
                       maxHeight:  targetHeight)
        }
        .sheet(isPresented: $showCameraTestTab) {
            CameraTestTabView()
        }
        .sheet(isPresented: $showPermissionGate) {
            PermissionGateView()
                .environment(permissionCoordinator)
        }
        .overlay(
            Group {
                if let info = groupInfoStore.groupInfo {
                    VStack {
                        Spacer()
                        
                        HStack {
                            GroupInfoFloatingButton(
                                groupInfo: info,
                                userName: userName,
                                isExpanded: $showGroupDetail
                            )
                            
                            Spacer()
                        }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 24)
                    }
                }
            }
        )
        .onAppear {
            #if DEBUG
            print("===== ContentView onAppear =====")
            print("groupInfoStore.groupInfo != nil: \(groupInfoStore.groupInfo != nil)")
            if let info = groupInfoStore.groupInfo {
                print("グループ名: \(info.groupName)")
                print("オーナー名: \(info.ownerName)")
                print("レコードID: \(info.recordID)")
            } else {
                print("グループ情報なし")
            }
            print("currentGroupID: \(currentGroupID)")
            print("userName: \(userName)")
            print("================================")
            #endif
        }
        .onChange(of: groupInfoStore.groupInfo) { oldValue, newValue in
            #if DEBUG
            print("===== GroupInfo Changed =====")
            print("Old value != nil: \(oldValue != nil)")
            print("New value != nil: \(newValue != nil)")
            if let info = newValue {
                print("新しいグループ名: \(info.groupName)")
                print("新しいオーナー名: \(info.ownerName)")
                print("新しいレコードID: \(info.recordID)")
            } else {
                print("グループ情報がクリアされました")
            }
            print("=============================")
            #endif
        }
    }

        // ContentView構造体内に以下のメソッドを追加
        private func fetchGroupInfoFromCloudKit(groupID: String) async {
            let zoneID = CloudKitService.workZoneID
            let groupRecordID = CKRecord.ID(recordName: groupID, zoneID: zoneID)
            let db = CKContainer.default().privateCloudDatabase
            
            do {
                let record = try await db.record(for: groupRecordID)
                
                let groupName = record["groupName"] as? String ?? "Unknown Group"
                let ownerName = record["ownerName"] as? String ?? "Unknown Owner"
                
                await MainActor.run {
                    GroupInfoStore.shared.groupInfo = GroupInfo(
                        groupName: groupName,
                        ownerName: ownerName,
                        recordID: groupID
                    )
                    
                    #if DEBUG
                    print("✅ CloudKitからグループ情報を復元しました")
                    print("グループ名: \(groupName)")
                    print("オーナー名: \(ownerName)")
                    #endif
                }
            } catch {
                #if DEBUG
                print("❌ CloudKitからの取得に失敗: \(error)")
                #endif
                
                // 取得に失敗した場合はリセット
                await MainActor.run {
                    currentGroupID = ""
                    userName = ""
                    
                    let alert = NSAlert()
                    alert.messageText = "グループ情報の取得に失敗"
                    alert.informativeText = "グループ情報を取得できませんでした。再度グループに参加してください。"
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }
    
    func shareGroupURL(_ urlString: String) {
        #if os(macOS)
        if let url = URL(string: urlString),
           let window = NSApp.keyWindow ?? NSApplication.shared.windows.first {
            let picker = NSSharingServicePicker(items: [url])
            picker.show(
                relativeTo: .zero,
                of: window.contentView!,
                preferredEdge: .maxY
            )
        }
        #endif
    }
    
    private func handleKeyDown(_ event: NSEvent) {
        switch event.keyCode {
        case 123:
            focusedButton = focusedButton.left()
        case 124:
            focusedButton = focusedButton.right()
        case 36, 76:
            triggerAction(for: focusedButton)
        default:
            break
        }
    }
    
    private func triggerAction(for focus: MainButtonFocus) {
        switch focus {
        case .additionalReport:
            break
        case .start:
            popupCoordinator.showTaskStartPopup = true
        case .management:
            openManagement()
        case .cameraTest:
            showCameraTestTab = true
        }
    }
    
    private func openManagement() {
        if let window = NSApp.keyWindow {
            parentWindowSize = window.frame.size
        }
        showManagement = true
    }
}

struct GroupInfoFloatingButton: View {
    let groupInfo: GroupInfo
    let userName: String
    @Binding var isExpanded: Bool
    @State private var isHovering = false
    @State private var showShareMenu = false
    @State private var copySuccess = false
    
    var body: some View {
        VStack(alignment: .trailing, spacing: 12) {
            if isExpanded {
                GroupDetailPanel(
                    groupInfo: groupInfo,
                    userName: userName,
                    copySuccess: $copySuccess,
                    showShareMenu: $showShareMenu,
                    onClose: {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                            isExpanded = false
                        }
                    }
                )
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.8, anchor: .bottomTrailing)
                        .combined(with: .opacity)
                        .combined(with: .offset(x: 0, y: 20)),
                    removal: .scale(scale: 0.8, anchor: .bottomTrailing)
                        .combined(with: .opacity)
                        .combined(with: .offset(x: 0, y: 20))
                ))
            }
            
            Button {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "person.3.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.white, .white.opacity(0.8)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("参加中のグループ")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.8))
                            .lineLimit(1)
                        
                        Text(groupInfo.groupName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                    }
                    
                    Image(systemName: isExpanded ? "chevron.down.circle.fill" : "chevron.up.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.white.opacity(0.9))
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.accentColor,
                                    Color.accentColor.opacity(0.8)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 5)
                        .overlay(
                            Capsule()
                                .strokeBorder(
                                    LinearGradient(
                                        colors: [
                                            Color.white.opacity(0.3),
                                            Color.white.opacity(0.1)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 1
                                )
                        )
                )
                .scaleEffect(isHovering ? 1.05 : 1.0)
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.2)) {
                    isHovering = hovering
                }
            }
        }
    }
}

struct GroupDetailPanel: View {
    let groupInfo: GroupInfo
    let userName: String
    @Binding var copySuccess: Bool
    @Binding var showShareMenu: Bool
    let onClose: () -> Void
    
    @State private var urlFieldHover = false
    @State private var actualShareURL: String? = nil
    @State private var isLoadingShareURL = false
    
    @AppStorage("currentGroupID") private var currentGroupID = ""
    @AppStorage("userName") private var storedUserName = ""
    
    private var shareURL: String {
        // 実際のCKShare URLがあればそれを使用
        if let actualURL = actualShareURL {
            return actualURL
        }
        // なければカスタムURL（フォールバック）
        return "monitoringsystem://share/\(groupInfo.recordID)"
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Color.purple, Color.blue],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 48, height: 48)
                        
                        Image(systemName: "person.3.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.white)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text(groupInfo.groupName)
                            .font(.system(size: 18, weight: .semibold))
                        
                        HStack(spacing: 4) {
                            Text("オーナー名：")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                            Text(groupInfo.ownerName)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                Spacer()
                
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 16) {
                InfoRow(
                    icon: "person.fill",
                    title: "あなたのユーザー名",
                    value: userName,
                    color: .blue
                )
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Label("招待用URL", systemImage: "link.circle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
                
                HStack(spacing: 8) {
                    if isLoadingShareURL {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(maxWidth: .infinity)
                    } else {
                        Text(shareURL)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.gray.opacity(0.1))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .strokeBorder(
                                                urlFieldHover ? Color.accentColor.opacity(0.3) : Color.gray.opacity(0.2),
                                                lineWidth: 1
                                            )
                                    )
                            )
                            .onHover { hovering in
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    urlFieldHover = hovering
                                }
                            }
                    }
                    
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(shareURL, forType: .string)
                        
                        withAnimation(.spring(response: 0.3)) {
                            copySuccess = true
                        }
                        
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            withAnimation {
                                copySuccess = false
                            }
                        }
                    } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(copySuccess ? Color.green : Color.accentColor)
                                .frame(width: 80, height: 36)
                            
                            HStack(spacing: 4) {
                                Image(systemName: copySuccess ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 14))
                                Text(copySuccess ? "Copied!" : "Copy")
                                    .font(.system(size: 13, weight: .medium))
                            }
                            .foregroundColor(.white)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .onAppear {
                fetchActualShareURL()
            }
            
            HStack(spacing: 12) {
                ShareButton(
                    url: shareURL,
                    showShareMenu: $showShareMenu
                )
                
                Spacer()
                
                Button {
                    let alert = NSAlert()
                    alert.messageText = "グループを退出しますか？"
                    alert.informativeText = "グループから退出すると、このグループの情報にアクセスできなくなり、すべてのローカルデータが削除されます。この操作は取り消せません。"
                    alert.addButton(withTitle: "退出する")
                    alert.addButton(withTitle: "キャンセル")
                    alert.alertStyle = .warning
                    
                    if let button = alert.buttons.first {
                        button.hasDestructiveAction = true
                    }
                    
                    if alert.runModal() == .alertFirstButtonReturn {
                        Task {
                            await SessionDataStore.shared.wipeAllPersistentData()
                            
                            CloudKitService.shared.clearTemporaryStorage()
                            
                            await MainActor.run {
                                GroupInfoStore.shared.groupInfo = nil
                                
                                currentGroupID = ""
                                storedUserName = ""
                                
                                UserDefaults.standard.removeObject(forKey: "currentGroupID")
                                UserDefaults.standard.removeObject(forKey: "userName")
                                UserDefaults.standard.synchronize()
                                
                                onClose()
                            }
                        }
                    }
                } label: {
                    Label("グループを退出", systemImage: "rectangle.portrait.and.arrow.right")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.red)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            Capsule()
                                .strokeBorder(Color.red.opacity(0.3), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(24)
        .frame(width: 400)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.15), radius: 20, x: 0, y: 10)
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.3),
                                    Color.white.opacity(0.1)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
        )
    }
    // 実際のCKShare URLを取得
    private func fetchActualShareURL() {
        isLoadingShareURL = true
        
        Task {
            let zoneID = CloudKitService.workZoneID
            let recordID = CKRecord.ID(recordName: groupInfo.recordID, zoneID: zoneID)
            let db = CKContainer.default().privateCloudDatabase
            
            do {
                // グループレコードを取得
                let groupRecord = try await db.record(for: recordID)
                
                // グループレコードに関連付けられたCKShareを取得
                if let shareReference = groupRecord.share {
                    do {
                        let shareRecord = try await db.record(for: shareReference.recordID)
                        
                        if let share = shareRecord as? CKShare {
                            await MainActor.run {
                                actualShareURL = share.url?.absoluteString
                                isLoadingShareURL = false
                                
                                #if DEBUG
                                print("✅ 実際のCKShare URL取得: \(actualShareURL ?? "nil")")
                                #endif
                            }
                        }
                    } catch {
                        #if DEBUG
                        print("⚠️ CKShare参照は存在するが取得できない: \(error)")
                        #endif
                        await MainActor.run {
                            isLoadingShareURL = false
                        }
                    }
                } else {
                    // shareReferenceがない場合、シンプルにカスタムURLを使用
                    await MainActor.run {
                        isLoadingShareURL = false
                        #if DEBUG
                        print("⚠️ グループレコードにCKShare参照がありません")
                        #endif
                    }
                }
            } catch {
                await MainActor.run {
                    isLoadingShareURL = false
                    #if DEBUG
                    print("❌ グループレコード取得エラー: \(error)")
                    #endif
                }
            }
        }
    }
}

struct InfoRow: View {
    let icon: String
    let title: String
    let value: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(color.opacity(0.1))
                    .frame(width: 36, height: 36)
                
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundColor(color)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                
                Text(value)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.primary)
            }
            
            Spacer()
        }
    }
}

struct ShareButton: View {
    let url: String
    @Binding var showShareMenu: Bool
    
    var body: some View {
        Button {
            if let shareURL = URL(string: url),
               let window = NSApp.keyWindow ?? NSApplication.shared.windows.first {
                let picker = NSSharingServicePicker(items: [shareURL])
                
                if let button = window.contentView?.subviews.first(where: { $0 is NSButton }) {
                    picker.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                } else {
                    picker.show(relativeTo: .zero, of: window.contentView!, preferredEdge: .maxY)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 14))
                Text("共有")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Color.accentColor, Color.accentColor.opacity(0.8)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

struct WindowMinSizeEnforcer: NSViewRepresentable {
    let minWidth:  CGFloat
    let minHeight: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let win = view.window else { return }
            let delegate = MinSizeDelegate(minW: minWidth, minH: minHeight,
                                           previous: win.delegate)
            win.delegate = delegate
            objc_setAssociatedObject(win, &MinSizeDelegate.key,
                                     delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            enforce(window: win)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let win = nsView.window { enforce(window: win) }
    }

    private func enforce(window: NSWindow) {
        let size = window.frame.size
        let minW = max(size.width,  minWidth )
        let minH = max(size.height, minHeight)
        if size.width < minWidth || size.height < minHeight {
            var frame = window.frame
            frame.size = NSSize(width: minW, height: minH)
            window.setFrame(frame, display: true, animate: false)
        }
        window.minSize = NSSize(width: minWidth, height: minHeight)
        window.contentMinSize = window.minSize
    }

    private final class MinSizeDelegate: NSObject, NSWindowDelegate {
        static var key = 0
        let minW: CGFloat
        let minH: CGFloat
        weak var previous: NSWindowDelegate?

        init(minW: CGFloat, minH: CGFloat, previous: NSWindowDelegate?) {
            self.minW = minW; self.minH = minH; self.previous = previous
        }

        func windowWillResize(_ sender: NSWindow,
                              to frameSize: NSSize) -> NSSize {
            var size = frameSize
            size.width  = max(size.width,  minW)
            size.height = max(size.height, minH)
            
            if let s = previous?.windowWillResize?(sender, to: size) {
                size.width  = max(size.width,  s.width)
                size.height = max(size.height, s.height)
            }
            return size
        }
        
        func windowDidBecomeKey(_ notification: Notification) {
            if let window = notification.object as? NSWindow {
                let size = window.frame.size
                let adjWidth = max(size.width, minW)
                let adjHeight = max(size.height, minH)
                
                if size.width < minW || size.height < minH {
                    var frame = window.frame
                    frame.size = NSSize(width: adjWidth, height: adjHeight)
                    window.setFrame(frame, display: true, animate: false)
                }
                
                previous?.windowDidBecomeKey?(notification)
            }
        }

        override func responds(to aSelector: Selector!) -> Bool {
            return super.responds(to: aSelector) ||
                   (previous?.responds(to: aSelector) ?? false)
        }
        override func forwardingTarget(for aSelector: Selector!) -> Any? {
            return previous?.responds(to: aSelector) == true ? previous : nil
        }
    }
}

