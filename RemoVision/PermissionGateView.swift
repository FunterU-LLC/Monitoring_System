import SwiftUI
import AppKit

struct PermissionGateView: View {
    @Environment(PermissionCoordinator.self) private var perm
    @State private var showPermissions = false
    @State private var currentStep = 0
    
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 255/255, green: 224/255, blue: 153/255).opacity(0.1),
                    Color(red: 255/255, green: 204/255, blue: 102/255).opacity(0.05)
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
            .frame(minWidth: 650, minHeight: 600)
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
        .frame(minWidth: 800, minHeight: 600)
        .padding(40)
    }
    
    private var headerSection: some View {
        VStack(spacing: 16) {
            Image(systemName: "shield.checkered")
                .font(.system(size: 60))
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            Color(red: 255/255, green: 204/255, blue: 102/255),
                            Color(red: 255/255, green: 184/255, blue: 77/255)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .symbolEffect(.pulse, value: showPermissions)
            
            Text("アプリの権限設定")
                .font(.system(size: 32, weight: .bold, design: .rounded))
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

            Text("最適な体験のために、以下の権限が必要です")
                .font(.system(size: 16))
                .foregroundColor(colorScheme == .dark ? .white.opacity(0.9) : .secondary)
        }
        .opacity(showPermissions ? 1 : 0)
        .offset(y: showPermissions ? 0 : -20)
    }
    
    private var permissionCardsSection: some View {
        VStack(spacing: 16) {
            permissionRow(
                icon: "checklist",
                title: "リマインダー",
                description: "タスクの管理",
                color: Color.appOrange,
                status: perm.remindersStatus,
                isActive: currentStep >= 0,
                delay: 0.0
            ) {
                openPrefs("Reminders")
            }
            
            permissionRow(
                icon: "camera.fill",
                title: "カメラ",
                description: "在席状況の自動検知（録画機能はありません）",
                color: Color.appOrange,
                status: perm.cameraStatus,
                isActive: currentStep >= 1,
                delay: 0.1
            ) {
                openPrefs("Camera")
            }
            
            permissionRow(
                icon: "accessibility",
                title: "アクセシビリティ",
                description: "アプリ使用状況の記録",
                color: Color.appOrange,
                status: perm.accessibilityStatus,
                isActive: currentStep >= 2,
                delay: 0.2
            ) {
                openPrefs("Accessibility")
            }
        }
        .padding(.horizontal, 40)
    }
    
    private var progressSection: some View {
        let granted = countGrantedPermissions()
        let progress = Double(granted) / 3.0
        let color = progressColor(for: progress)
        
        return ProgressBar(progress: progress, color: color)
            .frame(height: 8)
            .padding(.horizontal, 40)
            .opacity(showPermissions ? 1 : 0)
    }
    
    private var actionSection: some View {
        VStack(spacing: 16) {
            if perm.allGranted {
                CompletionView()
            }
        }
        .opacity(showPermissions ? 1 : 0)
        .offset(y: showPermissions ? 0 : 20)
    }
    
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
        case 0..<0.5: return Color(red: 255/255, green: 164/255, blue: 51/255)
        case 0.5..<1: return Color(red: 255/255, green: 204/255, blue: 102/255)
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
    
    @State private var isButtonHovering = false
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        HStack(spacing: 20) {
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
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(colorScheme == .dark ?
                        Color(red: 255/255, green: 224/255, blue: 153/255) :
                        Color(red: 92/255, green: 64/255, blue: 51/255))

                Text(description)
                    .font(.system(size: 14))
                    .foregroundColor(colorScheme == .dark ? .white.opacity(0.8) : .secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            Group {
                switch status {
                case .granted:
                    StatusBadge(
                        icon: "checkmark.circle.fill",
                        text: "許可済み",
                        color: .green
                    )
                case .denied, .unknown:
                    Button(action: action) {
                        HStack(spacing: 6) {
                            Image(systemName: "gear")
                            Text("設定を開く")
                        }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Color(red: 92/255, green: 64/255, blue: 51/255))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(color))
                        .scaleEffect(isButtonHovering ? 1.05 : 1)
                        .shadow(
                            color: isButtonHovering ? color.opacity(0.3) : color.opacity(0.1),
                            radius: isButtonHovering ? 8 : 4,
                            x: 0,
                            y: isButtonHovering ? 4 : 2
                        )
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            isButtonHovering = hovering
                        }
                    }
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
                    color: .black.opacity(0.05),
                    radius: 10,
                    x: 0,
                    y: 5
                )
        )
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
    @Environment(\.colorScheme) var colorScheme
    
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
                        colors: colorScheme == .dark ?
                            [.green.opacity(0.9), .green.opacity(0.7)] :
                            [.green, .green.opacity(0.8)],
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
