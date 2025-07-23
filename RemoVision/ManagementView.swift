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

    @State private var summaries: ([TaskUsageSummary], Int) = ([], 0)
    @State private var toastMessage: String? = nil
    @State private var toastWork: DispatchWorkItem? = nil
    @State private var errorMessage: String? = nil

    @AppStorage("currentGroupID") private var currentGroupID: String = ""
    @AppStorage("userName") private var userName: String = ""
    
    @State private var groupMembers: [String] = []
    @State private var selectedUser: String = ""
    @State private var isLoadingMembers: Bool = false
    
    @State private var isUpdatingCloudKit: Bool = false
    @State private var cloudKitUpdateMessage: String = ""
    
    @State private var userSearchText: String = ""
    
    @FocusState private var searchFieldFocused: Bool
    
    @State private var selectedParentTask: String = "全タスク"
    @State private var availableParentTasks: [String] = []

    private var tasks: [TaskUsageSummary] {
        summaries.0.sorted { $0.totalSeconds > $1.totalSeconds }
    }
    
    private var completedCount: Int { summaries.1 }
    
    private var filteredTasks: [TaskUsageSummary] {
        let filtered: [TaskUsageSummary]
        switch selectedParentTask {
        case "全タスク":
            filtered = tasks
        case "(親タスクなし)":
            filtered = tasks.filter { $0.parentTaskName == nil }
        default:
            filtered = tasks.filter { $0.parentTaskName == selectedParentTask }
        }
        return filtered.sorted { $0.totalSeconds > $1.totalSeconds }
    }

    private var filteredCompletedCount: Int {
        filteredTasks.filter { $0.isCompleted }.count
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
                            .foregroundColor(CloudKitService.shared.isOnline ? Color(red: 0/255, green: 128/255, blue: 0/255) : .red)
                    }
                    .padding(.bottom, 16)
                }

                userSelectionSection

                filterSection
                
                #if DEBUG
                Button("キャッシュをクリア") {
                    Task {
                        await CloudKitCacheStore.shared.clearAllCache()
                        await refreshSummaries()
                    }
                }
                .buttonStyle(.bordered)
                #endif

                if let error = errorMessage {
                    Text("エラー: \(error)")
                        .foregroundColor(.red)
                        .padding()
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(8)
                }

                kpiCards
                .buttonStyle(.borderedProminent)
                .tint(.red)

                taskTotalChart

                TaskAppStackedChartView(tasks: filteredTasks,
                                        toastMessage: $toastMessage,
                                        refreshAction: {
                                            Task { await refreshSummaries() }
                                        },
                                        refreshSummaries: refreshSummaries,
                                        isUpdatingCloudKit: $isUpdatingCloudKit,
                                        cloudKitUpdateMessage: $cloudKitUpdateMessage)
            }
            .padding(24)
            .task {
                await loadGroupMembers()
                await refreshSummaries()
            }
            .onAppear {
                searchFieldFocused = false
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
            .onChange(of: period) {
                Task { await refreshSummaries() }
            }
            .onChange(of: selectedUser) {
                Task { await refreshSummaries() }
            }
        }
        .background(
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    NSApp.keyWindow?.makeFirstResponder(nil)
                }
        )
        .overlay(
            Group {
                if isUpdatingCloudKit {
                    ZStack {
                        Color.black.opacity(0.5)
                            .edgesIgnoringSafeArea(.all)
                            .allowsHitTesting(!isUpdatingCloudKit)
                        
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
    }
}


private extension ManagementView {
    private var userSelectionSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("チームメンバー")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.secondary)
                
                Text("(\(groupMembers.count)人)")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary.opacity(0.7))
                
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    
                    TextField("検索", text: $userSearchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .frame(width: 150)
                        .focused($searchFieldFocused)
                    
                    if !userSearchText.isEmpty {
                        Button {
                            userSearchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.gray.opacity(0.1))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.gray.opacity(0.2), lineWidth: 1)
                        )
                )
                
                Spacer()
                
                if isLoadingMembers {
                    ProgressView()
                        .scaleEffect(0.7)
                        .progressViewStyle(CircularProgressViewStyle())
                } else {
                    Button {
                        Task {
                            await loadGroupMembers()
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("メンバーリストを更新")
                }
            }
            
            HStack {
                let filteredMembers = groupMembers.filter { member in
                    userSearchText.isEmpty || member.localizedCaseInsensitiveContains(userSearchText)
                }
                
                if filteredMembers.isEmpty && !userSearchText.isEmpty {
                    Text("メンバーが見つかりません")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .italic()
                } else {
                    MemberTextLinks(
                        members: filteredMembers,
                        selectedUser: $selectedUser,
                        currentUserName: userName
                    )
                }
                
                Spacer()
                
                if groupMembers.count > 1 {
                    Button {
                        cycleToNextUser()
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("次のメンバー")
                }
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.gray.opacity(0.15), lineWidth: 1)
                )
        )
    }
    
    struct MemberTextLinks: View {
        let members: [String]
        @Binding var selectedUser: String
        let currentUserName: String
        @State private var hoveredMember: String? = nil
        
        var body: some View {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    let orderedMembers: [String] = {
                        var result: [String] = []
                        
                        if members.contains(currentUserName) {
                            result.append(currentUserName)
                        }
                        
                        let otherMembers = members.filter { $0 != currentUserName }
                        result.append(contentsOf: otherMembers)
                        
                        return result
                    }()
                    
                    ForEach(orderedMembers, id: \.self) { member in
                        MemberTextLink(
                            member: member,
                            isSelected: selectedUser == member,
                            isCurrentUser: member == currentUserName,
                            isHovered: hoveredMember == member
                        ) {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                selectedUser = member
                            }
                        }
                        .onHover { hovering in
                            withAnimation(.easeInOut(duration: 0.15)) {
                                hoveredMember = hovering ? member : nil
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
    
    struct MemberTextLink: View {
        let member: String
        let isSelected: Bool
        let isCurrentUser: Bool
        let isHovered: Bool
        let action: () -> Void
        
        var body: some View {
            Button(action: action) {
                HStack(spacing: 6) {
                    if isCurrentUser {
                        Image(systemName: "star.fill")
                            .font(.system(size: 12))
                            .foregroundColor(isSelected ? Color(red: 92/255, green: 64/255, blue: 51/255) : Color(red: 255/255, green: 204/255, blue: 102/255))
                    }
                    
                    Text(member)
                        .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                        .foregroundColor(isSelected ? Color(red: 92/255, green: 64/255, blue: 51/255) : (isHovered ? .primary : .secondary))
                        .lineLimit(1)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(isSelected ? Color(red: 255/255, green: 204/255, blue: 102/255) : (isHovered ? Color.gray.opacity(0.15) : Color.gray.opacity(0.1)))
                        .overlay(
                            Capsule()
                                .strokeBorder(
                                    isSelected ? Color.clear : Color.gray.opacity(0.2),
                                    lineWidth: 1
                                )
                        )
                )
                .animation(.easeInOut(duration: 0.2), value: isSelected)
                .animation(.easeInOut(duration: 0.15), value: isHovered)
            }
            .buttonStyle(.plain)
        }
    }
    
    
    private func cycleToNextUser() {
        guard !groupMembers.isEmpty else { return }
        var orderedMembers: [String] = []
        if groupMembers.contains(userName) {
            orderedMembers.append(userName)
        }
        let otherMembers = groupMembers.filter { $0 != userName }
        orderedMembers.append(contentsOf: otherMembers)
        
        if let currentIndex = orderedMembers.firstIndex(of: selectedUser) {
            let nextIndex = (currentIndex + 1) % orderedMembers.count
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                selectedUser = orderedMembers[nextIndex]
            }
        }
    }
    
    private func extractParentTasks(from tasks: [TaskUsageSummary]) -> [String] {
        var options = ["全タスク"]
        
        let parentTaskNames = Set(tasks.compactMap { $0.parentTaskName })
        options.append(contentsOf: parentTaskNames.sorted())
        
        if tasks.contains(where: { $0.parentTaskName == nil }) {
            options.append("(親タスクなし)")
        }
        
        return options
    }
    
    
    var filterSection: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                ForEach(ReportPeriod.allCases) { p in
                    Text(p.rawValue)
                        .fontWeight(p == period ? .bold : .regular)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule()
                            .fill(p == period ? Color(red: 255/255, green: 204/255, blue: 102/255).opacity(0.25) : .clear))
                        .contentShape(Capsule())
                        .onTapGesture { period = p }
                }
            }
            
            if !availableParentTasks.isEmpty && availableParentTasks.count > 1 {
                HStack {
                    Label("親タスクでフィルター", systemImage: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                    
                    Picker("", selection: $selectedParentTask) {
                        ForEach(availableParentTasks, id: \.self) { parent in
                            HStack {
                                if parent == "全タスク" {
                                    Image(systemName: "list.bullet")
                                } else if parent == "(親タスクなし)" {
                                    Image(systemName: "minus.circle")
                                } else {
                                    Image(systemName: "folder")
                                }
                                Text(parent)
                            }
                            .tag(parent)
                        }
                    }
                    .pickerStyle(MenuPickerStyle())
                    .frame(width: 200)
                    
                    if selectedParentTask != "全タスク" {
                        Button {
                            withAnimation(.spring(response: 0.3)) {
                                selectedParentTask = "全タスク"
                            }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("フィルターをクリア")
                    }
                    
                    Spacer()
                    
                    Text("\(filteredTasks.count)タスク")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(Color.gray.opacity(0.1))
                        )
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.gray.opacity(0.05))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(Color.gray.opacity(0.1), lineWidth: 1)
                        )
                )
            }
        }
    }
    
    var kpiCards: some View {
        let totalSec = filteredTasks.reduce(0) { $0 + $1.totalSeconds }
        let displayedCompletedCount = selectedParentTask == "全タスク" ? completedCount : filteredCompletedCount
        
        return HStack(spacing: 16) {
            kpi("合計作業時間", totalSec.hmString, "clock.fill")
            kpi("完了タスク", "\(displayedCompletedCount)", "checkmark.circle.fill")
        }
        .animation(.spring(response: 0.01, dampingFraction: 0.3), value: displayedCompletedCount)
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
        let maxSec = filteredTasks.first?.totalSeconds ?? 1
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("タスク別作業時間")
                    .font(.headline)
                
                if selectedParentTask != "全タスク" {
                    Text("(\(selectedParentTask))")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            
            ForEach(filteredTasks) { task in
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
        
        guard !currentGroupID.isEmpty else {
            await MainActor.run {
                errorMessage = "グループIDが設定されていません"
                summaries = ([], 0)
            }
            return
        }
        
        let targetUser = selectedUser.isEmpty ? userName : selectedUser
        guard !targetUser.isEmpty else {
            await MainActor.run {
                errorMessage = "ユーザーが選択されていません"
                summaries = ([], 0)
            }
            return
        }
        
        await MainActor.run {
            isUpdatingCloudKit = true
            cloudKitUpdateMessage = "データを取得中です..."
            errorMessage = nil
        }
        
        do {
            
            let result = try await CloudKitService.shared.fetchUserSummaries(
                groupID: currentGroupID,
                userName: targetUser,
                forDays: period.days
            )
            
            await MainActor.run {
                let filteredSummaries = result.0.filter { !$0.taskName.hasPrefix("&") }
                let filteredResult = (filteredSummaries, result.1)
                
                withAnimation(.easeInOut(duration: 0.4)) {
                    summaries = filteredResult
                }
                availableParentTasks = extractParentTasks(from: summaries.0)
                if !availableParentTasks.contains(selectedParentTask) {
                    selectedParentTask = "全タスク"
                }
                
                isUpdatingCloudKit = false
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                summaries = ([], 0)
                isUpdatingCloudKit = false
            }
        }
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
            withAnimation(.spring(response: 0.3)) {
                isLoadingMembers = true
            }
            isUpdatingCloudKit = true
            cloudKitUpdateMessage = "グループメンバーを取得中です..."
        }
        
        do {
            let members = try await CloudKitService.shared.fetchGroupMembers(groupID: currentGroupID)
            await MainActor.run {
                withAnimation(.spring(response: 0.3)) {
                    groupMembers = members
                    if groupMembers.contains(userName) {
                        selectedUser = userName
                    } else if let firstMember = groupMembers.first {
                        selectedUser = firstMember
                    } else {
                        selectedUser = ""
                    }
                    isLoadingMembers = false
                }
                isUpdatingCloudKit = false
            }
        } catch {
            await MainActor.run {
                withAnimation(.spring(response: 0.3)) {
                    groupMembers = [userName]
                    selectedUser = userName
                    isLoadingMembers = false
                }
                isUpdatingCloudKit = false
            }
        }
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
                    toggleCompletion()
                } label: {
                    Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(task.isCompleted ? .green : .orange)
                }
                .buttonStyle(.plain)
                
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
                        Text(task.parentTaskName != nil ? "\(task.parentTaskName!) - \(task.taskName)" : task.taskName)
                            .font(.subheadline)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(task.parentTaskName != nil ? "\(task.parentTaskName!) - \(task.taskName)" : task.taskName)
                        
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
                
                Button {
                    showDelete = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .opacity(rowHover ? 1 : 0)

                Text(task.totalSeconds.hmString)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .foregroundColor(.gray)
                    .padding(.leading, 4)
            }
            .contentShape(Rectangle())
            .onTapGesture {
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
                .contentShape(Rectangle())
                .onTapGesture {
                    if !isEditingName {
                        withAnimation(.spring(response: 0.4,
                                              dampingFraction: 0.65,
                                              blendDuration: 0)) {
                            isExpanded.toggle()
                        }
                    }
                }
                .onHover { hovering in
                    if hovering && !isEditingName {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
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
        
        if let ek = remindersManager.store.calendarItem(withIdentifier: task.reminderId) as? EKReminder {
            let tItem = TaskItem(id: ek.calendarItemIdentifier,
                                 title: ek.title,
                                 dueDate: ek.dueDateComponents?.date,
                                 isCompleted: ek.isCompleted,
                                 notes: ek.notes)
            remindersManager.removeTask(tItem)
        }
        
        Task {
            await MainActor.run {
                isUpdatingCloudKit = true
                cloudKitUpdateMessage = "変更を適用中です..."
            }
            
            do {
                try await CloudKitService.shared.deleteTask(
                    groupID: currentGroupID,
                    taskReminderId: task.reminderId
                )
                
                await MainActor.run {
                    cloudKitUpdateMessage = "データを更新中です..."
                }
                
                await refreshSummaries()
                
                await MainActor.run {
                    isUpdatingCloudKit = false
                    toastMessage = "『\(task.taskName)』を削除しました。"
                }
            } catch {
                await MainActor.run {
                    isUpdatingCloudKit = false
                    toastMessage = "削除中にエラーが発生しました: \(error.localizedDescription)"
                    refreshAction()
                }
            }
        }
    }
    
    private func commitRename() {
        
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
                
                await MainActor.run {
                    cloudKitUpdateMessage = "データを更新中です..."
                }
                
                await refreshSummaries()
                
                await MainActor.run {
                    isUpdatingCloudKit = false
                    toastMessage = "'\(task.taskName)' を '\(trimmed)' に変更しました。"
                }
            } catch {
                await MainActor.run {
                    isUpdatingCloudKit = false
                    toastMessage = "名前変更中にエラーが発生しました: \(error.localizedDescription)"
                    refreshAction()
                }
            }
        }
    }
    
    private func toggleCompletion() {
        
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
            return
        }
        
        let newState = !task.isCompleted
        
        Task {
            await MainActor.run {
                isUpdatingCloudKit = true
                cloudKitUpdateMessage = "変更を適用中です..."
            }
            
            await MainActor.run {
                remindersManager.updateTask(item, completed: newState, notes: nil)
            }
            
            do {
                try await CloudKitService.shared.updateTaskCompletion(
                    groupID: currentGroupID,
                    taskReminderId: task.reminderId,
                    isCompleted: newState
                )
                
                await MainActor.run {
                    cloudKitUpdateMessage = "データを更新中です..."
                }
                
                await refreshSummaries()
                
                await MainActor.run {
                    remindersManager.fetchTasks(for: remindersManager.selectedList) { _ in
                    }
                }
                
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
        Color(red: 255/255, green: 204/255, blue: 102/255)
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
                        Text(task.parentTaskName != nil ? "\(task.parentTaskName!) - \(task.taskName)" : task.taskName)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(task.parentTaskName != nil ? "\(task.parentTaskName!) - \(task.taskName)" : task.taskName)
                        
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
                        
                        Button {
                            showDelete = true
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .opacity(rowHover ? 1 : 0)
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
        
        if let ek = remindersManager.store.calendarItem(withIdentifier: task.reminderId) as? EKReminder {
            let tItem = TaskItem(id: ek.calendarItemIdentifier,
                                 title: ek.title,
                                 dueDate: ek.dueDateComponents?.date,
                                 isCompleted: ek.isCompleted,
                                 notes: ek.notes)
            remindersManager.removeTask(tItem)
        }
        
        Task {
            await MainActor.run {
                isUpdatingCloudKit = true
                cloudKitUpdateMessage = "変更を適用中です..."
            }
            
            do {
                try await CloudKitService.shared.deleteTask(
                    groupID: currentGroupID,
                    taskReminderId: task.reminderId
                )
                
                await MainActor.run {
                    cloudKitUpdateMessage = "データを更新中です..."
                }
                
                await refreshSummaries()
                
                await MainActor.run {
                    isUpdatingCloudKit = false
                    toastMessage = "『\(task.taskName)』を削除しました。"
                }
            } catch {
                await MainActor.run {
                    isUpdatingCloudKit = false
                    toastMessage = "削除中にエラーが発生しました: \(error.localizedDescription)"
                    refreshAction()
                }
            }
        }
    }
    
    private func commitRename() {
        
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
                
                await MainActor.run {
                    cloudKitUpdateMessage = "データを更新中です..."
                }
                
                await refreshSummaries()
                
                await MainActor.run {
                    isUpdatingCloudKit = false
                    toastMessage = "'\(task.taskName)' を '\(trimmed)' に変更しました。"
                }
            } catch {
                await MainActor.run {
                    isUpdatingCloudKit = false
                    toastMessage = "名前変更中にエラーが発生しました: \(error.localizedDescription)"
                    refreshAction()
                }
            }
        }
    }
    
    private func toggleCompletion() {
        
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
            return
        }
        
        let newState = !task.isCompleted
        
        Task {
            await MainActor.run {
                isUpdatingCloudKit = true
                cloudKitUpdateMessage = "変更を適用中です..."
            }
            
            await MainActor.run {
                remindersManager.updateTask(item, completed: newState, notes: nil)
            }
            
            do {
                try await CloudKitService.shared.updateTaskCompletion(
                    groupID: currentGroupID,
                    taskReminderId: task.reminderId,
                    isCompleted: newState
                )
                
                await MainActor.run {
                    cloudKitUpdateMessage = "データを更新中です..."
                }
                
                await refreshSummaries()
                
                await MainActor.run {
                    remindersManager.fetchTasks(for: remindersManager.selectedList) { _ in
                    }
                }
                
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
