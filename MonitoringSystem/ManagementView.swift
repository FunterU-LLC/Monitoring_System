//ManagementView.swift
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
    @Environment(SessionDataStore.self) var store
    @Environment(AppUsageManager.self) var appUsageManager
    @Environment(\.dismiss) private var dismiss
    @Environment(RemindersManager.self) var remindersManager
    @State private var period: ReportPeriod = .today
    private let palette: [Color] = [.accentColor, .green, .orange, .pink,
                                    .purple, .yellow, .mint, .red]

    @State private var summaries: ([TaskUsageSummary], Int) = ([], 0)
    @State private var toastMessage: String? = nil
    @State private var toastWork: DispatchWorkItem? = nil

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
        let cal       = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        return (0..<7).map { off in
            let dayStart = cal.date(byAdding: .day, value: -off, to: todayStart)!
            let cnt = store.allSessions
                .filter { cal.isDate($0.endTime, inSameDayAs: dayStart) }
                .reduce(0) { $0 + $1.completedCount }
            return cnt
        }.reversed()
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
                periodSelector

                kpiCards

                Button("データ初期化") {
                    Task { await SessionDataStore.shared.wipeAllPersistentData() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)

                taskTotalChart

                TaskAppStackedChartView(tasks: tasks,
                                        toastMessage: $toastMessage,
                                        refreshAction: {
                                            Task { await refreshSummaries() }
                                        })

                CompletionLineChartView(points: completionTrend,
                                        maxValue: completionTrend.max() ?? 1)
                    .frame(height: 160)
            }
            .padding(24)
            .task { await refreshSummaries() }
            .onChange(of: period) {
                Task { await refreshSummaries() }
            }
        }
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
                              })
            }
        }
    }

    func refreshSummaries() async {
        let result = await store.summaries(forDays: period.days)
        await MainActor.run {
            withAnimation(.easeInOut(duration: 0.4)) {
                summaries = result
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
    @Environment(RemindersManager.self) var remindersManager

    @State private var isExpanded: Bool = false
    @State private var nameHover = false
    @State private var isEditingName = false
    @State private var editName = ""
    @State private var showDelete = false
    @State private var rowHover: Bool = false

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
        Button {
            withAnimation(.spring(response: 0.4,
                            dampingFraction: 0.65,
                            blendDuration: 0)) {
                isExpanded.toggle()
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Button {
                        toggleCompletion()
                    } label: {
                        // TaskStackedRow 内
                        Image(systemName: task.isCompleted ? "checkmark.circle.fill"
                                                           : "xmark.circle.fill")
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
                
                // (removed HStack that displayed timestamps here)

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
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onTapGesture {
            if isEditingName {
                withAnimation { isEditingName = false }
            }
        }
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
        SessionDataStore.shared.removeAllRecords(for: task.reminderId)
        toastMessage = "『\(task.taskName)』を削除しました。"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { refreshAction() }
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

        SessionDataStore.shared.updateTaskTitle(reminderId: task.reminderId, newTitle: trimmed)
        toastMessage = "'\(task.taskName)' を '\(trimmed)' に変更しました。"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { refreshAction() }
        isEditingName = false
    }

    private func toggleCompletion() {
        Task {
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
            guard let item = target else { return }
            
            let newState = !task.isCompleted
            remindersManager.updateTask(item, completed: newState, notes: nil)

            SessionDataStore.shared.updateTaskCompletion(reminderId: task.reminderId,
                                                         isCompleted: newState)

            await MainActor.run {
                toastMessage = newState
                    ? "'\(task.taskName)'を達成済に切り替えました"
                    : "'\(task.taskName)'を未達成に切り替えました"
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                refreshAction()
                remindersManager.fetchTasks(for: remindersManager.selectedList) { _ in }
            }
        }
    }
}


private struct TaskAppStackedChartView: View {
    let tasks: [TaskUsageSummary]
    @Binding var toastMessage: String?
    let refreshAction: () -> Void

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
                                            refreshAction: refreshAction) }
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
    @Environment(\.colorScheme) private var colorScheme

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
        if let ek = remindersManager.store.calendarItem(withIdentifier: task.reminderId) as? EKReminder {
            let tItem = TaskItem(id: ek.calendarItemIdentifier,
                                 title: ek.title,
                                 dueDate: ek.dueDateComponents?.date,
                                 isCompleted: ek.isCompleted,
                                 notes: ek.notes)
            remindersManager.removeTask(tItem)
        }
        SessionDataStore.shared.removeAllRecords(for: task.reminderId)
        toastMessage = "『\(task.taskName)』を削除しました。"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { refreshAction() }
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

        SessionDataStore.shared.updateTaskTitle(reminderId: task.reminderId, newTitle: trimmed)

        toastMessage = "'\(task.taskName)' を '\(trimmed)' に変更しました。"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { refreshAction() }
        isEditing = false
    }

    private func toggleCompletion() {
        Task {
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
            guard let item = target else { return }

            let newState = !task.isCompleted
            remindersManager.updateTask(item, completed: newState, notes: nil)
            SessionDataStore.shared.updateTaskCompletion(reminderId: task.reminderId,
                                                         isCompleted: newState)

            await MainActor.run {
                toastMessage = newState
                    ? "'\(task.taskName)'を達成済に切り替えました"
                    : "'\(task.taskName)'を未達成に切り替えました"
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                refreshAction()
                remindersManager.fetchTasks(for: remindersManager.selectedList) { _ in }
            }
        }
    }
}

private extension TimeInterval {
    var hmString: String {
        "\(Int(self) / 3600)h \((Int(self) % 3600) / 60)m"
    }
}
