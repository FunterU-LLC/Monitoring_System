import SwiftUI
import Charts
import EventKit

enum ReportPeriod: String, CaseIterable, Identifiable {
    case today = "当日", twoDays = "2日間", threeDays = "3日間"
    case oneWeek = "1週間", twoWeeks = "2週間", oneMonth = "1ヶ月"

    var id: String { rawValue }
    var days: Int {
        switch self {
        case .today:     return 1
        case .twoDays:   return 2
        case .threeDays: return 3
        case .oneWeek:   return 7
        case .twoWeeks:  return 14
        case .oneMonth:  return 30
        }
    }
}

struct ManagementView: View {
    @Environment(AppUsageManager.self) var appUsageManager
    @Environment(\.dismiss) private var dismiss
    @Environment(RemindersManager.self) var remindersManager
    @State private var period: ReportPeriod = .today
    private let palette: [Color] = [.accentColor, .green, .orange, .pink,
                                    .purple, .yellow, .mint, .red]

    @State private var summaries: ([TaskUsageSummary], Int) = ([], 0)
    @State private var toastMessage: String? = nil
    @State private var toastWork: DispatchWorkItem? = nil
    @State private var errorMessage: String? = nil
    
    @State private var showDeleteConfirmation = false
    @State private var deleteAction: (() async -> Void)? = nil
    @State private var deleteMessage = ""

    @AppStorage("currentGroupID") private var currentGroupID: String = ""
    @AppStorage("userName") private var userName: String = ""
    
    @State private var groupMembers: [String] = []
    @State private var selectedUser: String = ""
    @State private var isLoadingMembers: Bool = false
    
    @State private var isUpdatingCloudKit: Bool = false
    @State private var cloudKitUpdateMessage: String = ""
    
    @State private var userSearchText: String = ""

    private var tasks: [TaskUsageSummary] {
        summaries.0.sorted { $0.totalSeconds > $1.totalSeconds }
    }
    
    private var completedCount: Int { summaries.1 }

    private var overallAppUsageRatios: [(name: String, ratio: Double)] {
        var dict: [String: Double] = [:]
        
        for t in tasks {
            for a in t.appBreakdown {
                dict[a.name, default: 0] += a.seconds
            }
        }
        
        for rec in appUsageManager.aggregatedResults {
            dict[rec.appName, default: 0] += rec.totalTime
        }
        
        let total = dict.values.reduce(0, +)
        guard total > 0 else { return [] }
        
        return dict.map { ($0.key, $0.value / total) }
                   .sorted { $0.ratio > $1.ratio }
    }

    private var completionTrend: [Int] {
        // CloudKitからの取得は未実装のため、仮データを返す
        // 実装する場合は、過去7日間のデータを個別に取得する必要がある
        return Array(repeating: completedCount / 7, count: 7)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack {
                    Button("戻る") {
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                }
                
                if !currentGroupID.isEmpty && !userName.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("グループメンバー: \(groupMembers.count)人")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("ネットワーク状態: \(CloudKitService.shared.getNetworkStatus())")
                            .font(.caption)
                            .foregroundColor(CloudKitService.shared.isOnline ? .green : .red)
                    }
                    .padding(.bottom, 16)
                }

                userSelectionSection

                periodSelector

                if let error = errorMessage {
                    Text("エラー: \(error)")
                        .foregroundColor(.red)
                        .padding()
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(8)
                }

                kpiCards
                debugDeletionSection

                Button("データ初期化") {
                    Task {
                        await clearCloudKitData()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)

                taskTotalChart

                TaskAppStackedChartView(tasks: tasks,
                                        toastMessage: $toastMessage,
                                        refreshAction: {
                                            Task { await refreshSummaries() }
                                        },
                                        refreshSummaries: refreshSummaries,
                                        isUpdatingCloudKit: $isUpdatingCloudKit,
                                        cloudKitUpdateMessage: $cloudKitUpdateMessage)

                CompletionLineChartView(points: completionTrend,
                                        maxValue: completionTrend.max() ?? 1)
                    .frame(height: 160)
            }
            .padding(24)
            .task {
                await loadGroupMembers()
                await refreshSummaries()
            }
            .onChange(of: period) {
                Task { await refreshSummaries() }
            }
            .onChange(of: selectedUser) {
                Task { await refreshSummaries() }
            }
            .onChange(of: summaries.0.count) { oldValue, newValue in
                print("📊 [ManagementView] Task count changed: \(oldValue) -> \(newValue)")
            }
            .onChange(of: summaries.1) { oldValue, newValue in
                print("📊 [ManagementView] Completed count changed: \(oldValue) -> \(newValue)")
            }
        }
        .overlay(
            Group {
                if isUpdatingCloudKit {
                    ZStack {
                        Color.black.opacity(0.5)
                            .edgesIgnoringSafeArea(.all)
                        
                        VStack(spacing: 16) {
                            ProgressView()
                                .scaleEffect(1.5)
                                .progressViewStyle(CircularProgressViewStyle())
                                .colorScheme(.dark)
                            
                            Text(cloudKitUpdateMessage)
                                .foregroundColor(.white)
                                .font(.headline)
                        }
                        .padding(32)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color.black.opacity(0.8))
                        )
                    }
                    .transition(.opacity)
                }
            }
        )
        .animation(.easeInOut(duration: 0.3), value: isUpdatingCloudKit)
        .overlay(
            Group {
                if let msg = toastMessage {
                    Text(msg)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 24)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.black.opacity(0.85))
                        )
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .transition(.opacity)
                }
            },
            alignment: .center
        )
        .onChange(of: toastMessage) { _, newValue in
            toastWork?.cancel()
            guard newValue != nil else { return }
            let work = DispatchWorkItem {
                withAnimation { toastMessage = nil }
            }
            toastWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
        }
        .alert("危険な操作", isPresented: $showDeleteConfirmation) {
                    Button("キャンセル", role: .cancel) {}
                    Button("削除実行", role: .destructive) {
                        if let action = deleteAction {
                            Task { await action() }
                        }
                    }
                } message: {
                    Text(deleteMessage)
                }
    }
    
    private func clearCloudKitData() async {
        CloudKitService.shared.clearTemporaryStorage()
        toastMessage = "一時保存データをクリアしました"
        await refreshSummaries()
    }
}

private struct TaskChartRow: View {
    let task: TaskUsageSummary
    let palette: [Color]

    private var data: [TaskAppBarDatum] {
        task.appBreakdown.map { app in
            TaskAppBarDatum(taskName: task.taskName,
                            appName:  app.name,
                            seconds:  app.seconds)
        }
    }

    var body: some View {
        Chart(data) { item in
            BarMark(
                x: .value("時間(s)", item.seconds),
                y: .value("タスク",   item.taskName)
            )
            .position(by: .value("App", item.appName))
            .foregroundStyle(by: .value("App", item.appName))
        }
        .chartForegroundStyleScale(domain: data.map(\.appName),
                                   range: palette)
        .chartLegend(.hidden)
        .frame(height: 22)
        .padding(.vertical, 2)
    }
}

private extension ManagementView {
    var userSelectionSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("ユーザー選択", systemImage: "person.2.fill")
                    .font(.headline)
                
                Spacer()
                
                // 検索フィールド
                HStack {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                    
                    TextField("メンバーを検索", text: $userSearchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                    
                    if !userSearchText.isEmpty {
                        Button {
                            userSearchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(NSColor.controlBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.gray.opacity(0.2), lineWidth: 1)
                        )
                )
                .frame(width: 200)
                
                if isLoadingMembers {
                    ProgressView()
                        .scaleEffect(0.7)
                } else {
                    Button {
                        Task { await loadGroupMembers() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14))
                    }
                    .buttonStyle(.plain)
                    .help("メンバーリストを更新")
                }
            }
            
            // フィルタリングされたメンバーリスト
            let filteredMembers = groupMembers.filter { member in
                userSearchText.isEmpty || member.localizedCaseInsensitiveContains(userSearchText)
            }
            let filteredOtherMembers = filteredMembers.filter { $0 != userName }
            let showCurrentUser = filteredMembers.contains(userName)
            
            // カード形式のユーザー選択（自分を固定）
            HStack(spacing: 0) {
                // 自分のカード（固定）- 検索結果に含まれる場合のみ表示
                if groupMembers.contains(userName) && showCurrentUser {
                    UserSelectionCard(
                        userName: userName,
                        isSelected: selectedUser == userName,
                        isCurrentUser: true,
                        isLoading: isLoadingMembers
                    ) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            selectedUser = userName
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(selectedUser == userName ? Color.blue.opacity(0.1) : Color.clear)
                            .animation(.easeInOut(duration: 0.2), value: selectedUser)
                    )
                    .padding(.trailing, 12)
                    
                    // セパレーター（他のメンバーがいる場合のみ）
                    if !filteredOtherMembers.isEmpty {
                        Divider()
                            .frame(height: 60)
                            .padding(.trailing, 12)
                    }
                }
                
                // 他のメンバーのカード（スクロール可能）
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        if filteredOtherMembers.isEmpty {
                            // 検索結果がない場合のメッセージ
                            Text(userSearchText.isEmpty ? "他のメンバーはいません" : "検索結果がありません")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(minWidth: 200, minHeight: 80)
                                .frame(maxWidth: .infinity)
                        } else {
                            ForEach(filteredOtherMembers, id: \.self) { member in
                                UserSelectionCard(
                                    userName: member,
                                    isSelected: selectedUser == member,
                                    isCurrentUser: false,
                                    isLoading: isLoadingMembers
                                ) {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                        selectedUser = member
                                    }
                                }
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(selectedUser == member ? Color.blue.opacity(0.1) : Color.clear)
                                        .animation(.easeInOut(duration: 0.2), value: selectedUser)
                                )
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(height: 80)
            }
            
            // 検索中の情報表示
            if !userSearchText.isEmpty {
                HStack {
                    Image(systemName: "info.circle")
                        .font(.caption2)
                    Text("\(filteredMembers.count)人が検索にマッチしました")
                        .font(.caption2)
                    Spacer()
                    Button("クリア") {
                        userSearchText = ""
                    }
                    .font(.caption2)
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                }
                .foregroundColor(.secondary)
                .padding(.horizontal, 4)
                .padding(.top, -8)
            }
            
            // 選択中のユーザー情報
            if !selectedUser.isEmpty {
                HStack(spacing: 8) {
                    Circle()
                        .fill(selectedUser == userName ? Color.blue : Color.green)
                        .frame(width: 8, height: 8)
                    
                    Text(selectedUser == userName ? "自分の作業記録を表示中" : "\(selectedUser) の作業記録を表示中")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    if !isLoadingMembers && groupMembers.count > 1 {
                        Text("\(groupMembers.count)人のメンバー")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(NSColor.controlBackgroundColor).opacity(0.5))
                )
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
                .shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
        )
    }

    // カスタムユーザー選択カード
    struct UserSelectionCard: View {
        let userName: String
        let isSelected: Bool
        let isCurrentUser: Bool
        let isLoading: Bool
        let action: () -> Void
        
        @State private var isHovering = false
        
        private var initials: String {
            userName
                .split(separator: " ")
                .compactMap { $0.first }
                .map { String($0) }
                .prefix(2)
                .joined()
                .uppercased()
        }
        
        private var backgroundColor: Color {
            if isSelected {
                return Color.accentColor
            } else if isHovering {
                return Color.gray.opacity(0.2)
            } else {
                return Color(NSColor.controlBackgroundColor)
            }
        }
        
        var body: some View {
            Button(action: action) {
                VStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .fill(backgroundColor)
                            .frame(width: 44, height: 44)
                        
                        if isSelected {
                            Image(systemName: "person.fill")
                                .foregroundColor(.white)
                                .font(.system(size: 20))
                        } else {
                            Text(initials)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(isHovering ? .primary : .secondary)
                        }
                        
                        if isCurrentUser {
                            Circle()
                                .fill(Color.blue)
                                .frame(width: 12, height: 12)
                                .overlay(
                                    Circle()
                                        .strokeBorder(Color.white, lineWidth: 2)
                                )
                                .offset(x: 16, y: -16)
                        }
                    }
                    
                    Text(userName)
                        .font(.caption)
                        .lineLimit(1)
                        .frame(width: 70)
                        .foregroundColor(isSelected ? .accentColor : .primary)
                    
                    if isCurrentUser {
                        Text("(自分)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 4)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.clear)
                )
            }
            .buttonStyle(.plain)
            .scaleEffect(isSelected ? 1.05 : 1.0)
            .disabled(isLoading)
            .opacity(isLoading ? 0.6 : 1.0)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.2)) {
                    isHovering = hovering
                }
            }
        }
    }
    
    var periodSelector: some View {
        HStack(spacing: 12) {
            ForEach(ReportPeriod.allCases) { p in
                Text(p.rawValue)
                    .fontWeight(p == period ? .bold : .regular)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule()
                        .fill(p == period ? Color.accentColor.opacity(0.25) : .clear))
                    .contentShape(Capsule())
                    .onTapGesture { period = p }
            }
        }
    }

    var kpiCards: some View {
        let totalSec = tasks.reduce(0) { $0 + $1.totalSeconds }
        return HStack(spacing: 16) {
            kpi("合計作業時間", totalSec.hmString, "clock.fill")
            kpi("完了タスク", "\(completedCount)", "checkmark.circle.fill")
        }
        .animation(.spring(response: 0.01, dampingFraction: 0.3), value: completedCount)
        .animation(.spring(response: 0.01, dampingFraction: 0.3), value: totalSec)
    }

    func kpi(_ title: String, _ value: String, _ sf: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: sf).font(.title2)
            Text(value)
                .font(.title3).bold()
                .id(value)
                .transition(.opacity.combined(with: .scale))
            Text(title).font(.caption).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(RoundedRectangle(cornerRadius: 12)
            .fill(Color(NSColor.controlBackgroundColor)))
    }

    private var taskTotalChart: some View {
        let maxSec = tasks.first?.totalSeconds ?? 1
        return VStack(alignment: .leading, spacing: 4) {
            Text("タスク別作業時間").font(.headline)
            ForEach(tasks) { task in
                TaskLengthRow(task: task,
                              maxSeconds: maxSec,
                              toastMessage: $toastMessage,
                              refreshAction: {
                                  Task { await refreshSummaries() }
                              },
                              refreshSummaries: refreshSummaries,
                              isUpdatingCloudKit: $isUpdatingCloudKit,
                              cloudKitUpdateMessage: $cloudKitUpdateMessage)
            }
        }
    }

    func refreshSummaries() async {
        print("🔄 [ManagementView] Starting refreshSummaries...")
        
        guard !currentGroupID.isEmpty else {
            await MainActor.run {
                errorMessage = "グループIDが設定されていません"
                summaries = ([], 0)
            }
            print("❌ [ManagementView] No groupID set")
            return
        }
        
        let targetUser = selectedUser.isEmpty ? userName : selectedUser
        guard !targetUser.isEmpty else {
            await MainActor.run {
                errorMessage = "ユーザーが選択されていません"
                summaries = ([], 0)
            }
            print("❌ [ManagementView] No user selected")
            return
        }

        await MainActor.run {
            isUpdatingCloudKit = true
            cloudKitUpdateMessage = "データを取得中です..."
            errorMessage = nil
        }

        do {
            print("🔄 Fetching CloudKit data for user: \(targetUser), period: \(period.days) days")
            print("  - GroupID: \(currentGroupID)")
            print("  - User: \(targetUser)")
            print("  - Period: \(period.days) days")
            
            let result = try await CloudKitService.shared.fetchUserSummaries(
                groupID: currentGroupID,
                userName: targetUser,
                forDays: period.days
            )
            
            await MainActor.run {
                print("📊 [ManagementView] Updating UI with \(result.0.count) tasks")
                print("  - Completed count: \(result.1)")
                for task in result.0.prefix(3) {
                    print("  - Task: '\(task.taskName)' (completed: \(task.isCompleted))")
                }
                if result.0.count > 3 {
                    print("  - ... and \(result.0.count - 3) more tasks")
                }
                
                withAnimation(.easeInOut(duration: 0.4)) {
                    summaries = result
                }
                isUpdatingCloudKit = false
                print("✅ CloudKit data loaded: \(result.0.count) tasks, \(result.1) completed")
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                summaries = ([], 0)
                isUpdatingCloudKit = false
                print("❌ Failed to fetch CloudKit data: \(error)")
                print("  - Error details: \(error.localizedDescription)")
            }
        }
        
        print("✅ [ManagementView] refreshSummaries completed")
    }

    func loadGroupMembers() async {
        guard !currentGroupID.isEmpty else {
            await MainActor.run {
                groupMembers = []
                selectedUser = userName
            }
            return
        }
        
        await MainActor.run {
            isUpdatingCloudKit = true
            cloudKitUpdateMessage = "グループメンバーを取得中です..."
        }
        
        do {
            let members = try await CloudKitService.shared.fetchGroupMembers(groupID: currentGroupID)
            await MainActor.run {
                groupMembers = members
                if groupMembers.contains(userName) {
                    selectedUser = userName
                } else if let firstMember = groupMembers.first {
                    selectedUser = firstMember
                } else {
                    selectedUser = ""
                }
                isUpdatingCloudKit = false
                print("✅ Loaded \(members.count) group members")
            }
        } catch {
            await MainActor.run {
                groupMembers = [userName]
                selectedUser = userName
                isUpdatingCloudKit = false
                print("❌ Failed to load group members: \(error)")
            }
        }
    }
    
    var debugDeletionSection: some View {
            #if DEBUG
            VStack(alignment: .leading, spacing: 12) {
                Text("🚨 デバッグ用削除機能")
                    .font(.headline)
                    .foregroundColor(.red)
                
                Text("注意: これらの操作は元に戻せません")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                HStack(spacing: 12) {
                    Button("一時保存データクリア") {
                        CloudKitService.shared.clearTemporaryStorage()
                        toastMessage = "一時保存データをクリアしました"
                    }
                    .buttonStyle(.bordered)
                    
                    Button("データ統計表示") {
                        Task {
                            do {
                                try await CloudKitService.shared.printCloudKitDataStats()
                                toastMessage = "データ統計をコンソールに出力しました"
                            } catch {
                                toastMessage = "統計取得失敗: \(error.localizedDescription)"
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                }
                
                HStack(spacing: 12) {
                    Button("選択ユーザーのデータ削除") {
                        let targetUser = selectedUser.isEmpty ? userName : selectedUser
                        deleteMessage = "ユーザー「\(targetUser)」のすべてのデータを削除しますか？"
                        deleteAction = {
                            await deleteUserData(targetUser)
                        }
                        showDeleteConfirmation = true
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(selectedUser.isEmpty && userName.isEmpty)
                    
                    Button("全データ削除") {
                        deleteMessage = "CloudKit内のALLデータを削除しますか？この操作は元に戻せません。"
                        deleteAction = {
                            await deleteAllCloudKitData()
                        }
                        showDeleteConfirmation = true
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            }
            .padding()
            .background(Color.red.opacity(0.1))
            .cornerRadius(12)
            #else
            EmptyView()
            #endif
        }
        
        private func deleteUserData(_ userName: String) async {
            do {
                try await CloudKitService.shared.deleteUserData(groupID: currentGroupID, userName: userName)
                await MainActor.run {
                    toastMessage = "ユーザー「\(userName)」のデータを削除しました"
                }
                await refreshSummaries()
                await loadGroupMembers()
            } catch {
                await MainActor.run {
                    toastMessage = "削除失敗: \(error.localizedDescription)"
                }
            }
        }
        
        private func deleteAllCloudKitData() async {
            do {
                try await CloudKitService.shared.deleteAllCloudKitData()
                await MainActor.run {
                    toastMessage = "すべてのCloudKitデータを削除しました"
                    groupMembers = []
                    selectedUser = ""
                    summaries = ([], 0)
                }
            } catch {
                await MainActor.run {
                    toastMessage = "削除失敗: \(error.localizedDescription)"
                }
            }
        }
}

private struct TaskTotalRow: View {
    let task: TaskUsageSummary
    let palette: [Color]

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            Text(task.taskName)
                .frame(width: 120, alignment: .leading)

            GeometryReader { geo in
                let totalWidth = geo.size.width
                let safeTotal  = max(task.totalSeconds, 1)
                HStack(spacing: 0) {
                    ForEach(Array(task.appBreakdown.enumerated()), id: \.offset) { idx, app in
                        let w = totalWidth * CGFloat(app.seconds) / CGFloat(safeTotal)
                        Rectangle()
                            .fill(palette[idx % palette.count])
                            .frame(width: max(w, 1), height: 18)
                    }
                }
            }
            .frame(height: 18)
            .layoutPriority(1)
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(task.totalSeconds.hmString)
                .frame(width: 70, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct TaskStackedRow: View {
    let task: TaskUsageSummary
    let colorMap: [String: Color]
    @Binding var toastMessage: String?
    let refreshAction: () -> Void
    let refreshSummaries: () async -> Void
    @Environment(RemindersManager.self) var remindersManager

    @State private var isExpanded: Bool = false
    @State private var localIsCompleted: Bool? = nil
    @State private var nameHover = false
    @State private var isEditingName = false
    @State private var editName = ""
    @State private var showDelete = false
    @State private var rowHover: Bool = false
    
    @AppStorage("currentGroupID") private var currentGroupID: String = ""
    
    @Binding var isUpdatingCloudKit: Bool
    @Binding var cloudKitUpdateMessage: String

    private let minLabelWidth: CGFloat = 60
    private let barHeight:     CGFloat = 18

    private var segments: [(color: Color, name: String, ratio: Double, percent: Int)] {
        let total = max(task.appBreakdown.reduce(0) { $0 + $1.seconds }, 1)

        struct Tmp { let name: String; let sec: Double; let pct: Double }
        let sorted = task.appBreakdown
            .map { Tmp(name: $0.name,
                       sec: $0.seconds,
                       pct: $0.seconds / total) }
            .sorted { $0.sec > $1.sec }

        let threshold = 0.03
        let visible   = sorted.filter { $0.pct >= threshold }
        let hiddenPct = sorted.filter { $0.pct < threshold }
                              .reduce(0) { $0 + $1.pct }

        var items = visible
        if hiddenPct > 0 {
            items.append(Tmp(name: "その他",
                             sec: hiddenPct * total,
                             pct: hiddenPct))
        }

        var percents = items.map { Int(round($0.pct * 100)) }
        if let first = percents.indices.first {
            percents[first] += 100 - percents.reduce(0, +)
        }

        return items.enumerated().map { idx, it in
            let p = percents[idx]
            let col = (it.name == "その他")
                ? Color.gray
                : (colorMap[it.name] ?? .gray)
            return (col, it.name, Double(p) / 100.0, p)
        }
    }

    private var detailSegments: [(name: String, percent: Int, seconds: TimeInterval)] {
        let total = max(task.appBreakdown.reduce(0) { $0 + $1.seconds }, 1)
        return task.appBreakdown
            .map { app in
                let pct = Int(round(app.seconds / total * 100))
                return (app.name, pct, app.seconds)
            }
            .sorted { $0.seconds > $1.seconds }
    }

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale.current
        df.dateFormat = "yyyy/MM/dd HH:mm"
        return df
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button {
                    // このボタンアクションは使用されない
                } label: {
                    Image(systemName: (localIsCompleted ?? task.isCompleted) ? "checkmark.circle.fill"
                                                                             : "xmark.circle.fill")
                        .foregroundColor((localIsCompleted ?? task.isCompleted) ? .green : .orange)
                }
                .buttonStyle(.plain)
                .onTapGesture {
                    // 明示的にtoggleCompletionを呼び出す
                    toggleCompletion()
                }

                if isEditingName {
                    TextField("", text: $editName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                        .onSubmit { commitRename() }
                    Button("キャンセル") { isEditingName = false }
                        .buttonStyle(.bordered)
                    Button("決定") { commitRename() }
                        .buttonStyle(.borderedProminent)
                        .disabled(editName.trimmingCharacters(in: .whitespaces).isEmpty ||
                                  editName == task.taskName)
                } else {
                    HStack(spacing: 4) {
                        Text(task.taskName)
                            .font(.subheadline)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(task.taskName)

                        if nameHover {
                            Button {
                                editName = task.taskName
                                isEditingName = true
                            } label: { Image(systemName: "pencil") }
                              .buttonStyle(.plain)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(width: 200, alignment: .leading)
                    .contentShape(Rectangle())
                    .onHover { nameHover = $0 }
                }

                Spacer()

                if rowHover {
                    Button {
                        showDelete = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                }

                Text(task.totalSeconds.hmString)
                    .font(.caption2)
                    .foregroundColor(.secondary)

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .foregroundColor(.gray)
                    .padding(.leading, 4)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                // 行全体をタップした時は展開/折りたたみ
                if !isEditingName {
                    withAnimation(.spring(response: 0.4,
                                    dampingFraction: 0.65,
                                    blendDuration: 0)) {
                        isExpanded.toggle()
                    }
                }
            }

            GeometryReader { geo in
                let totalW = geo.size.width
                HStack(spacing: 0) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                        let w = totalW * CGFloat(seg.ratio)
                        Rectangle()
                            .fill(seg.color)
                            .frame(width: w, height: barHeight)
                            .overlay(
                                w >= minLabelWidth ?
                                    Text("\(seg.name.prefix(10)) \(seg.percent)%")
                                        .font(.caption2)
                                        .foregroundColor(.white)
                                    : nil
                            )
                    }
                }
            }
            .frame(height: barHeight)

            if isExpanded {
                HStack(alignment: .top, spacing: 32) {

                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(detailSegments, id: \.name) { seg in
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(colorMap[seg.name] ?? .gray)
                                        .frame(width: 8, height: 8)
                                    Text(seg.name)
                                }
                                .frame(width: 120, alignment: .leading)

                                Text("\(seg.percent)%")
                                    .frame(width: 40, alignment: .trailing)

                                Text(": \(seg.seconds.hmString)")
                                    .frame(alignment: .leading)
                            }
                            .font(.caption)
                        }
                    }

                    VStack(alignment: .trailing, spacing: 6) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("コメント")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            if let note = task.comment, !note.isEmpty {
                                Text(note)
                                    .font(.caption)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                Text("コメントがありません")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)

                    VStack(alignment: .trailing, spacing: 2) {
                        Text("開始: \(task.startTime, formatter: Self.dateFormatter)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("終了: \(task.endTime, formatter: Self.dateFormatter)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .contentShape(Rectangle())
        .animation(.spring(response: 0.4,
                           dampingFraction: 0.65,
                           blendDuration: 0),
                   value: isExpanded)
        .onHover { rowHover = $0 }
        .alert("確認", isPresented: $showDelete) {
            Button("キャンセル", role: .cancel) {}
            Button("はい", role: .destructive) { deleteTask() }
        } message: {
            Text("『\(task.taskName)』を削除しますか？")
        }
    }

    private func deleteTask() {
        print("🔄 [TaskStackedRow] deleteTask called for task: '\(task.taskName)'")
        
        if let ek = remindersManager.store.calendarItem(withIdentifier: task.reminderId) as? EKReminder {
            let tItem = TaskItem(id: ek.calendarItemIdentifier,
                                title: ek.title,
                                dueDate: ek.dueDateComponents?.date,
                                isCompleted: ek.isCompleted,
                                notes: ek.notes)
            remindersManager.removeTask(tItem)
        }
        
        Task {
            // 最初に「変更を適用中」を表示
            await MainActor.run {
                isUpdatingCloudKit = true
                cloudKitUpdateMessage = "変更を適用中です..."
            }
            
            do {
                try await CloudKitService.shared.deleteTask(
                    groupID: currentGroupID,
                    taskReminderId: task.reminderId
                )
                print("  - CloudKit delete successful")
                
                // CloudKit更新成功後、UIを更新
                await MainActor.run {
                    print("  - Refreshing UI...")
                    cloudKitUpdateMessage = "データを更新中です..."
                }
                
                // UIのリフレッシュを実行
                await refreshSummaries()
                
                // すべて完了したら成功メッセージを表示
                await MainActor.run {
                    isUpdatingCloudKit = false
                    toastMessage = "『\(task.taskName)』を削除しました。"
                }
            } catch {
                await MainActor.run {
                    isUpdatingCloudKit = false
                    toastMessage = "削除中にエラーが発生しました: \(error.localizedDescription)"
                    print("  - CloudKit delete failed: \(error)")
                    // エラー時でもUI更新を試みる
                    refreshAction()
                }
            }
        }
    }
    
    private func commitRename() {
        print("🔄 [TaskStackedRow] commitRename called for task: '\(task.taskName)' -> '\(editName)'")
        
        let trimmed = editName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != task.taskName else { return }

        if let ek = remindersManager.store.calendarItem(withIdentifier: task.reminderId) as? EKReminder {
            let taskItem = TaskItem(id: ek.calendarItemIdentifier,
                                    title: ek.title,
                                    dueDate: ek.dueDateComponents?.date,
                                    isCompleted: ek.isCompleted,
                                    notes: ek.notes)
            remindersManager.renameTask(taskItem, to: trimmed)
        }

        Task {
            // 最初に「変更を適用中」を表示
            await MainActor.run {
                isUpdatingCloudKit = true
                cloudKitUpdateMessage = "変更を適用中です..."
                isEditingName = false
            }
            
            do {
                try await CloudKitService.shared.updateTaskName(
                    groupID: currentGroupID,
                    taskReminderId: task.reminderId,
                    newName: trimmed
                )
                print("  - CloudKit update successful")
                
                // CloudKit更新成功後、UIを更新
                await MainActor.run {
                    print("  - Refreshing UI...")
                    cloudKitUpdateMessage = "データを更新中です..."
                }
                
                // UIのリフレッシュを実行
                await refreshSummaries()
                
                // すべて完了したら成功メッセージを表示
                await MainActor.run {
                    isUpdatingCloudKit = false
                    toastMessage = "'\(task.taskName)' を '\(trimmed)' に変更しました。"
                }
            } catch {
                await MainActor.run {
                    isUpdatingCloudKit = false
                    toastMessage = "名前変更中にエラーが発生しました: \(error.localizedDescription)"
                    print("  - CloudKit update failed: \(error)")
                    // エラー時でもUI更新を試みる
                    refreshAction()
                }
            }
        }
    }

    private func toggleCompletion() {
        print("🔄 [TaskStackedRow] toggleCompletion called for task: '\(task.taskName)'")
        
        var target = remindersManager.tasks.first { $0.id == task.reminderId }

        if target == nil, !task.reminderId.isEmpty {
            if let ek = remindersManager.store.calendarItem(withIdentifier: task.reminderId) as? EKReminder {
                target = TaskItem(id: ek.calendarItemIdentifier,
                                title: ek.title,
                                dueDate: ek.dueDateComponents?.date,
                                isCompleted: ek.isCompleted,
                                notes: ek.notes)
            }
        }
        guard let item = target else {
            print("❌ [TaskStackedRow] Task not found in reminders")
            return
        }

        let newState = !task.isCompleted
        print("  - Current state: \(task.isCompleted) -> New state: \(newState)")
        
        // CloudKit更新を開始
        Task {
            // 最初に「変更を適用中」を表示
            await MainActor.run {
                isUpdatingCloudKit = true
                cloudKitUpdateMessage = "変更を適用中です..."
            }
            
            // リマインダーを更新
            await MainActor.run {
                remindersManager.updateTask(item, completed: newState, notes: nil)
                print("  - Updated in Reminders")
            }
            
            do {
                print("  - Updating in CloudKit...")
                try await CloudKitService.shared.updateTaskCompletion(
                    groupID: currentGroupID,
                    taskReminderId: task.reminderId,
                    isCompleted: newState
                )
                print("  - CloudKit update successful")
                
                // CloudKit更新成功後、UIを更新
                await MainActor.run {
                    print("  - Refreshing UI...")
                    cloudKitUpdateMessage = "データを更新中です..."
                }
                
                // UIのリフレッシュを実行
                await refreshSummaries()
                
                // リマインダーも再取得
                await MainActor.run {
                    remindersManager.fetchTasks(for: remindersManager.selectedList) { _ in
                        print("  - Reminders re-fetched")
                    }
                }
                
                // すべて完了したら成功メッセージを表示
                await MainActor.run {
                    isUpdatingCloudKit = false
                    toastMessage = newState
                        ? "'\(task.taskName)'を達成済に切り替えました"
                        : "'\(task.taskName)'を未達成に切り替えました"
                }
                
            } catch {
                await MainActor.run {
                    isUpdatingCloudKit = false
                    toastMessage = "CloudKit更新に失敗しました: \(error.localizedDescription)"
                    print("  - CloudKit update failed: \(error)")
                    // エラー時でもUI更新を試みる
                    refreshAction()
                }
            }
        }
    }
}

private struct TaskAppStackedChartView: View {
    let tasks: [TaskUsageSummary]
    @Binding var toastMessage: String?
    let refreshAction: () -> Void
    let refreshSummaries: () async -> Void
    @Binding var isUpdatingCloudKit: Bool
    @Binding var cloudKitUpdateMessage: String

    private var colorMap: [String: Color] {
        var map: [String: Color] = [:]
        for t in tasks {
            for a in t.appBreakdown {
                map[a.name] = AppColorManager.shared.color(for: a.name)
            }
        }
        map["その他"] = .gray
        return map
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("タスク内アプリ比率").font(.headline)
            ForEach(tasks) { TaskStackedRow(task: $0,
                                            colorMap: colorMap,
                                            toastMessage: $toastMessage,
                                            refreshAction: refreshAction,
                                            refreshSummaries: refreshSummaries,
                                            isUpdatingCloudKit: $isUpdatingCloudKit,
                                            cloudKitUpdateMessage: $cloudKitUpdateMessage) }
        }
    }
}

private struct CompletionLineChartView: View {
    let points: [Int]
    let maxValue: Int
    var body: some View {
        VStack(alignment: .leading) {
            Text("完了タスク推移").font(.headline)
            GeometryReader { geo in
                let pts = makePoints(size: geo.size)
                Path { p in
                    guard let first = pts.first else { return }
                    p.move(to: first)
                    pts.dropFirst().forEach { p.addLine(to: $0) }
                }
                .stroke(Color.accentColor, lineWidth: 2)
                ForEach(pts.indices, id: \.self) { idx in
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                        .position(pts[idx])
                }
            }
        }
    }
    private func makePoints(size: CGSize) -> [CGPoint] {
        guard maxValue > 0 else { return [] }
        let cnt = max(points.count - 1, 1)
        return points.enumerated().map { idx, v in
            let x = CGFloat(idx) / CGFloat(cnt) * size.width
            let y = size.height - CGFloat(v) / CGFloat(maxValue) * size.height
            return CGPoint(x: x, y: y)
        }
    }
}

private struct OverallAppUsageBarView: View {
    let usages: [(name: String, ratio: Double)]
    let palette: [Color]
    var body: some View {
        GeometryReader { geo in
            let totalWidth = geo.size.width
            HStack(spacing: 0) {
                ForEach(Array(usages.enumerated()), id: \.offset) { idx, u in
                    let width = totalWidth * CGFloat(u.ratio)
                    Rectangle()
                        .fill(palette[idx % palette.count])
                        .frame(width: width)
                        .overlay(width >= 40 ? Text("\(u.name.prefix(10)) \(Int(u.ratio * 100))%")
                                    .font(.caption2).foregroundColor(.white) : nil)
                }
            }
        }
        .frame(height: 18)
    }
}

private struct TaskLengthRow: View {
    let task: TaskUsageSummary
    let maxSeconds: Double
    @Binding var toastMessage: String?
    let refreshAction: () -> Void
    let refreshSummaries: () async -> Void
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("currentGroupID") private var currentGroupID: String = ""
    
    @Binding var isUpdatingCloudKit: Bool
    @Binding var cloudKitUpdateMessage: String

    private var barColor: Color {
        colorScheme == .dark
            ? Color.orange
            : Color.accentColor
    }
    
    @State private var hovering = false
    @State private var isEditing = false
    @State private var newName   = ""
    @State private var showDelete = false
    @State private var rowHover = false

    @Environment(RemindersManager.self) var remindersManager

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { toggleCompletion() } label: {
                    Image(systemName: task.isCompleted ? "checkmark.circle.fill"
                                                       : "xmark.circle.fill")
                        .foregroundColor(task.isCompleted ? .green : .orange)
                }
                .buttonStyle(.plain)

                if isEditing {
                    TextField("", text: $newName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                        .onSubmit { commitRename() }
                    Button("キャンセル") { withAnimation { isEditing = false } }
                        .buttonStyle(.bordered)
                    Button("決定") { commitRename() }
                        .buttonStyle(.borderedProminent)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty ||
                                  newName == task.taskName)
                    Spacer(minLength: 0)
                } else {
                    HStack(spacing: 4) {
                        Text(task.taskName)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(task.taskName)

                        if hovering {
                            Button {
                                newName = task.taskName
                                withAnimation { isEditing = true }
                            } label: { Image(systemName: "pencil") }
                              .buttonStyle(.plain)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(width: 200, alignment: .leading)
                    .contentShape(Rectangle())
                    .onHover { hovering = $0 }

                    GeometryReader { geo in
                        let ratio = CGFloat(task.totalSeconds / max(maxSeconds, 1))
                        let rawW  = geo.size.width * ratio
                        Rectangle()
                            .fill(barColor.opacity( colorScheme == .dark ? 0.4 : 0.25))
                            .frame(width: max(rawW, 4), height: 24)
                            .cornerRadius(4)
                    }
                    .frame(height: 18)
                    .layoutPriority(1)

                    HStack(spacing: 4) {
                        Text(task.totalSeconds.hmString)
                            .frame(width: 70, alignment: .trailing)
                        if rowHover {
                            Button {
                                showDelete = true
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            if isEditing {
                HStack(spacing: 6) {
                    Spacer()
                        .frame(width: 24 + 6 + 200)

                    GeometryReader { geo in
                        let ratio = CGFloat(task.totalSeconds / max(maxSeconds, 1))
                        let rawW  = geo.size.width * ratio
                        Rectangle()
                            .fill(barColor.opacity(0.25))
                            .frame(width: max(rawW, 4), height: 24)
                            .cornerRadius(4)
                    }
                    .frame(height: 18)
                    .layoutPriority(1)

                    Text(task.totalSeconds.hmString)
                        .frame(width: 70, alignment: .trailing)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onHover { rowHover = $0 }
        .alert("確認", isPresented: $showDelete) {
            Button("キャンセル", role: .cancel) {}
            Button("はい", role: .destructive) { deleteTask() }
        } message: {
            Text("『\(task.taskName)』を削除しますか？")
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            if isEditing {
                withAnimation { isEditing = false }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isEditing)
    }

    private func deleteTask() {
        print("🔄 [TaskLengthRow] deleteTask called for task: '\(task.taskName)'")
        
        if let ek = remindersManager.store.calendarItem(withIdentifier: task.reminderId) as? EKReminder {
            let tItem = TaskItem(id: ek.calendarItemIdentifier,
                                 title: ek.title,
                                 dueDate: ek.dueDateComponents?.date,
                                 isCompleted: ek.isCompleted,
                                 notes: ek.notes)
            remindersManager.removeTask(tItem)
        }
        
        Task {
            // 最初に「変更を適用中」を表示
            await MainActor.run {
                isUpdatingCloudKit = true
                cloudKitUpdateMessage = "変更を適用中です..."
            }
            
            do {
                try await CloudKitService.shared.deleteTask(
                    groupID: currentGroupID,
                    taskReminderId: task.reminderId
                )
                print("  - CloudKit delete successful")
                
                // CloudKit更新成功後、UIを更新
                await MainActor.run {
                    print("  - Refreshing UI...")
                    cloudKitUpdateMessage = "データを更新中です..."
                }
                
                // UIのリフレッシュを実行
                await refreshSummaries()
                
                // すべて完了したら成功メッセージを表示
                await MainActor.run {
                    isUpdatingCloudKit = false
                    toastMessage = "『\(task.taskName)』を削除しました。"
                }
            } catch {
                await MainActor.run {
                    isUpdatingCloudKit = false
                    toastMessage = "削除中にエラーが発生しました: \(error.localizedDescription)"
                    print("  - CloudKit delete failed: \(error)")
                    // エラー時でもUI更新を試みる
                    refreshAction()
                }
            }
        }
    }
    
    private func commitRename() {
        print("🔄 [TaskLengthRow] commitRename called for task: '\(task.taskName)' -> '\(newName)'")
        
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != task.taskName else { return }

        if let ek = remindersManager.store.calendarItem(withIdentifier: task.reminderId) as? EKReminder {
            let taskItem = TaskItem(id: ek.calendarItemIdentifier,
                                    title: ek.title,
                                    dueDate: ek.dueDateComponents?.date,
                                    isCompleted: ek.isCompleted,
                                    notes: ek.notes)
            remindersManager.renameTask(taskItem, to: trimmed)
        }

        Task {
            // 最初に「変更を適用中」を表示
            await MainActor.run {
                isUpdatingCloudKit = true
                cloudKitUpdateMessage = "変更を適用中です..."
                isEditing = false
            }
            
            do {
                try await CloudKitService.shared.updateTaskName(
                    groupID: currentGroupID,
                    taskReminderId: task.reminderId,
                    newName: trimmed
                )
                print("  - CloudKit update successful")
                
                // CloudKit更新成功後、UIを更新
                await MainActor.run {
                    print("  - Refreshing UI...")
                    cloudKitUpdateMessage = "データを更新中です..."
                }
                
                // UIのリフレッシュを実行
                await refreshSummaries()
                
                // すべて完了したら成功メッセージを表示
                await MainActor.run {
                    isUpdatingCloudKit = false
                    toastMessage = "'\(task.taskName)' を '\(trimmed)' に変更しました。"
                }
            } catch {
                await MainActor.run {
                    isUpdatingCloudKit = false
                    toastMessage = "名前変更中にエラーが発生しました: \(error.localizedDescription)"
                    print("  - CloudKit update failed: \(error)")
                    // エラー時でもUI更新を試みる
                    refreshAction()
                }
            }
        }
    }

    private func toggleCompletion() {
        print("🔄 [TaskLengthRow] toggleCompletion called for task: '\(task.taskName)'")
        
        var target = remindersManager.tasks.first { $0.id == task.reminderId }

        if target == nil, !task.reminderId.isEmpty {
            if let ek = remindersManager.store.calendarItem(withIdentifier: task.reminderId) as? EKReminder {
                target = TaskItem(id: ek.calendarItemIdentifier,
                                  title: ek.title,
                                  dueDate: ek.dueDateComponents?.date,
                                  isCompleted: ek.isCompleted,
                                  notes: ek.notes)
            }
        }
        guard let item = target else {
            print("❌ [TaskLengthRow] Task not found in reminders")
            return
        }

        let newState = !task.isCompleted
        print("  - Current state: \(task.isCompleted) -> New state: \(newState)")
        
        Task {
            // 最初に「変更を適用中」を表示
            await MainActor.run {
                isUpdatingCloudKit = true
                cloudKitUpdateMessage = "変更を適用中です..."
            }
            
            // リマインダーを更新
            await MainActor.run {
                remindersManager.updateTask(item, completed: newState, notes: nil)
                print("  - Updated in Reminders")
            }
            
            do {
                print("  - Updating in CloudKit...")
                try await CloudKitService.shared.updateTaskCompletion(
                    groupID: currentGroupID,
                    taskReminderId: task.reminderId,
                    isCompleted: newState
                )
                print("  - CloudKit update successful")
                
                // CloudKit更新成功後、UIを更新
                await MainActor.run {
                    print("  - Refreshing UI...")
                    cloudKitUpdateMessage = "データを更新中です..."
                }
                
                // UIのリフレッシュを実行
                await refreshSummaries()
                
                // リマインダーも再取得
                await MainActor.run {
                    remindersManager.fetchTasks(for: remindersManager.selectedList) { _ in
                        print("  - Reminders re-fetched")
                    }
                }
                
                // すべて完了したら成功メッセージを表示
                await MainActor.run {
                    isUpdatingCloudKit = false
                    toastMessage = newState
                        ? "'\(task.taskName)'を達成済に切り替えました"
                        : "'\(task.taskName)'を未達成に切り替えました"
                }
                
            } catch {
                await MainActor.run {
                    isUpdatingCloudKit = false
                    toastMessage = "CloudKit更新に失敗しました: \(error.localizedDescription)"
                    print("  - CloudKit update failed: \(error)")
                    // エラー時でもUI更新を試みる
                    refreshAction()
                }
            }
        }
    }
}

private extension TimeInterval {
    var hmString: String {
        "\(Int(self) / 3600)h \((Int(self) % 3600) / 60)m"
    }
}
