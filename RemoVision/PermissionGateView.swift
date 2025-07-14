import SwiftUI
import AppKit

struct PermissionGateView: View {
    @Environment(PermissionCoordinator.self) private var perm
    @State private var isRequesting = false
    @State private var showPermissions = false
    @State private var currentStep = 0
    
    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.1),
                    Color.purple.opacity(0.05)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            
            VStack(spacing: 40) {
                headerSection
                permissionCardsSection
                progressSection
                actionSection
            }
            .frame(minWidth: 600, minHeight: 700)
            .padding(40)
        }
        .onAppear {
            withAnimation(.spring(response: 0.8, dampingFraction: 0.7).delay(0.2)) {
                showPermissions = true
            }
            updateCurrentStep()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            perm.recheckAll()
            updateCurrentStep()
        }
    }
    
    // Header section
    private var headerSection: some View {
        VStack(spacing: 16) {
            Image(systemName: "shield.checkered")
                .font(.system(size: 60))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.accentColor, .purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .symbolEffect(.pulse, value: showPermissions)
            
            Text("アプリの権限設定")
                .font(.system(size: 32, weight: .bold, design: .rounded))
            
            Text("最適な体験のために、以下の権限が必要です")
                .font(.system(size: 16))
                .foregroundColor(.secondary)
        }
        .opacity(showPermissions ? 1 : 0)
        .offset(y: showPermissions ? 0 : -20)
    }
    
    // Permission cards section
    private var permissionCardsSection: some View {
        VStack(spacing: 16) {
            // Reminders permission
            permissionRow(
                icon: "checklist",
                title: "リマインダー",
                description: "タスクの管理と追跡",
                color: .orange,
                status: perm.remindersStatus,
                isActive: currentStep >= 0,
                delay: 0.0
            ) {
                openPrefs("Reminders")
            }
            
            // Camera permission
            permissionRow(
                icon: "camera.fill",
                title: "カメラ",
                description: "在席状況の自動検知",
                color: .blue,
                status: perm.cameraStatus,
                isActive: currentStep >= 1,
                delay: 0.1
            ) {
                openPrefs("Camera")
            }
            
            // Accessibility permission
            permissionRow(
                icon: "accessibility",
                title: "アクセシビリティ",
                description: "アプリ使用状況の記録",
                color: .purple,
                status: perm.accessibilityStatus,
                isActive: currentStep >= 2,
                delay: 0.2
            ) {
                perm.promptAccessibilityPanel()
            }
        }
        .padding(.horizontal, 40)
    }
    
    // Progress section
    private var progressSection: some View {
        let granted = countGrantedPermissions()
        let progress = Double(granted) / 3.0
        let color = progressColor(for: progress)
        
        return ProgressBar(progress: progress, color: color)
            .frame(height: 8)
            .padding(.horizontal, 40)
            .opacity(showPermissions ? 1 : 0)
    }
    
    // Action section
    private var actionSection: some View {
        VStack(spacing: 16) {
            if !perm.allGranted {
                requestPermissionsButton
            } else {
                CompletionView()
            }
        }
        .opacity(showPermissions ? 1 : 0)
        .offset(y: showPermissions ? 0 : 20)
    }
    
    private var requestPermissionsButton: some View {
        Button {
            requestAllPermissions()
        } label: {
            HStack {
                if isRequesting {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .scaleEffect(0.8)
                        .frame(width: 20, height: 20)
                } else {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 20))
                }
                Text(isRequesting ? "設定中..." : "すべての権限を許可")
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 32)
            .padding(.vertical, 16)
            .background(
                LinearGradient(
                    colors: [Color.accentColor, Color.purple],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .cornerRadius(12)
            .shadow(color: Color.accentColor.opacity(0.4), radius: 10, x: 0, y: 5)
        }
        .buttonStyle(.plain)
        .disabled(isRequesting)
    }
    
    // Helper function to create permission row
    private func permissionRow(
        icon: String,
        title: String,
        description: String,
        color: Color,
        status: PermissionCoordinator.Status,
        isActive: Bool,
        delay: Double,
        action: @escaping () -> Void
    ) -> some View {
        PermissionRow(
            icon: icon,
            title: title,
            description: description,
            color: color,
            status: status,
            isActive: isActive,
            action: action
        )
        .opacity(showPermissions ? 1 : 0)
        .offset(x: showPermissions ? 0 : -50)
        .animation(
            .spring(response: 0.6, dampingFraction: 0.8)
            .delay(delay),
            value: showPermissions
        )
    }
    
    private func countGrantedPermissions() -> Int {
        var count = 0
        if perm.remindersStatus == .granted { count += 1 }
        if perm.cameraStatus == .granted { count += 1 }
        if perm.accessibilityStatus == .granted { count += 1 }
        return count
    }
    
    private func progressColor(for progress: Double) -> Color {
        switch progress {
        case 0: return .red
        case 0..<0.5: return .orange
        case 0.5..<1: return .yellow
        default: return .green
        }
    }
    
    private func updateCurrentStep() {
        if perm.remindersStatus == .granted {
            currentStep = 1
            if perm.cameraStatus == .granted {
                currentStep = 2
                if perm.accessibilityStatus == .granted {
                    currentStep = 3
                }
            }
        }
    }
    
    private func requestAllPermissions() {
        Task {
            isRequesting = true
            if perm.remindersStatus != .granted { await perm.requestReminders() }
            if perm.cameraStatus != .granted { await perm.requestCamera() }
            perm.recheckAccessibility()
            updateCurrentStep()
            isRequesting = false
        }
    }
    
    private func openPrefs(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct PermissionRow: View {
    let icon: String
    let title: String
    let description: String
    let color: Color
    let status: PermissionCoordinator.Status
    let isActive: Bool
    let action: () -> Void
    
    @State private var isHovering = false
    
    var body: some View {
        HStack(spacing: 20) {
            // Icon section
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                color.opacity(0.2),
                                color.opacity(0.1)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 60, height: 60)
                
                Image(systemName: icon)
                    .font(.system(size: 28))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [color, color.opacity(0.8)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
            .opacity(isActive ? 1 : 0.5)
            
            // Content section
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.primary)
                
                Text(description)
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            // Status section
            Group {
                switch status {
                case .granted:
                    StatusBadge(
                        icon: "checkmark.circle.fill",
                        text: "許可済み",
                        color: .green
                    )
                case .denied:
                    Button(action: action) {
                        HStack(spacing: 6) {
                            Image(systemName: "gear")
                            Text("設定を開く")
                        }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(color))
                    }
                    .buttonStyle(.plain)
                case .unknown:
                    StatusBadge(
                        icon: "questionmark.circle",
                        text: "未設定",
                        color: .gray
                    )
                }
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(
                            status == .granted ? Color.green.opacity(0.3) : Color.gray.opacity(0.2),
                            lineWidth: 1
                        )
                )
                .shadow(
                    color: isHovering ? color.opacity(0.2) : .black.opacity(0.05),
                    radius: isHovering ? 15 : 10,
                    x: 0,
                    y: 5
                )
        )
        .scaleEffect(isHovering ? 1.02 : 1)
        .onHover { hovering in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                isHovering = hovering
            }
        }
    }
}

struct StatusBadge: View {
    let icon: String
    let text: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 16))
            Text(text)
                .font(.system(size: 14, weight: .medium))
        }
        .foregroundColor(color)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(color.opacity(0.1))
                .overlay(
                    Capsule()
                        .strokeBorder(color.opacity(0.3), lineWidth: 1)
                )
        )
    }
}

struct ProgressBar: View {
    let progress: Double
    let color: Color
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.2))
                
                RoundedRectangle(cornerRadius: 4)
                    .fill(
                        LinearGradient(
                            colors: [color, color.opacity(0.8)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geometry.size.width * progress)
                    .animation(.spring(response: 0.6, dampingFraction: 0.8), value: progress)
            }
        }
    }
}

struct CompletionView: View {
    @State private var showCheckmark = false
    
    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.green.opacity(0.2), .green.opacity(0.1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 80, height: 80)
                
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 50))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.green, .green.opacity(0.8)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .scaleEffect(showCheckmark ? 1 : 0)
                    .rotationEffect(.degrees(showCheckmark ? 0 : -180))
            }
            
            Text("すべての権限が許可されました")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.green, .green.opacity(0.8)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
        }
        .onAppear {
            withAnimation(.spring(response: 0.8, dampingFraction: 0.6).delay(0.2)) {
                showCheckmark = true
            }
        }
    }
}
