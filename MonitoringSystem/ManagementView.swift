//
//  ManagementView.swift
//  MonitoringSystemApp
//

import SwiftUI

enum ReportPeriod: String, CaseIterable, Identifiable {
    case today = "当日", twoDays = "2日", threeDays = "3日"
    case oneWeek = "1週", twoWeeks = "2週", oneMonth = "1月"
    var id: String { rawValue }
    var days: Int {
        switch self {
        case .today:      return 1
        case .twoDays:    return 2
        case .threeDays:  return 3
        case .oneWeek:    return 7
        case .twoWeeks:   return 14
        case .oneMonth:   return 30
        }
    }

}

struct ManagementView: View {
    @EnvironmentObject var store: SessionDataStore
//    private let store = SessionDataStore.shared   // actor
    @Environment var appUsageManager: AppUsageManager
    @State private var period: ReportPeriod = .today
    
    private let palette: [Color] = [.accentColor, .green, .orange, .pink,
                                    .purple, .yellow, .mint, .red]
    
    @State private var summaries: ([TaskUsageSummary], Int) = ([], 0)
    private var tasks: [TaskUsageSummary] {
        summaries.0.sorted { $0.totalSeconds > $1.totalSeconds }
    }
    private var overallAppUsageRatios: [(name: String, ratio: Double)] {
        var dict: [String: Double] = [:]
        for t in tasks {
            for a in t.appBreakdown {
                dict[a.name, default: 0] += a.seconds
            }
        }
        if dict.isEmpty {
            for rec in appUsageManager.aggregatedResults {
                dict[rec.appName, default: 0] += rec.totalTime
            }
        }
        
        let total = dict.values.reduce(0, +)
        guard total > 0 else { return [] }
        return dict.map { ($0.key, $0.value / total) }
                   .sorted { $0.ratio > $1.ratio }
    }

    private var completed: Int { summaries.1 }
    private var completionTrend: [Int] {
        let today = Calendar.current.startOfDay(for: Date())
        return (0..<7).map { off in
            let day = Calendar.current.date(byAdding: .day, value: -off, to: today)!
            return store.allSessions.filter {
                Calendar.current.isDate($0.date, inSameDayAs: day)
            }.reduce(0) { $0 + $1.completedCount }
        }.reversed()
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                periodSelector
                kpiCards
                Button("データ初期化") {
                    Task { await SessionDataStore.shared.wipeAllPersistentData() }
                }
                .buttonStyle(.borderedProminent)        // 見た目はお好みで
                .tint(.red)
                taskTotalChart
                TaskAppStackedChartView(tasks: tasks,
                                        overall: overallAppUsageRatios,
                                        palette: palette)

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
    }
}

private extension ManagementView {
    var periodSelector: some View {
        HStack(spacing: 12) {
            ForEach(ReportPeriod.allCases) { p in
                Text(p.rawValue)
                    .fontWeight(p == period ? .bold : .regular)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule()
                        .fill(p == period ? Color.accentColor.opacity(0.25) : .clear))
                    .contentShape(Capsule())
                    .onTapGesture { period = p }
            }
        }
    }
    var kpiCards: some View {
        let totalSec = tasks.reduce(0) { $0 + $1.totalSeconds }
        let appSec = tasks.flatMap(\.appBreakdown).reduce(0) { $0 + $1.seconds }
        return HStack(spacing: 16) {
            kpi("合計作業時間", totalSec.hmString, "clock.fill")
            kpi("アプリ使用時間", appSec.hmString, "desktopcomputer")
            kpi("完了タスク", "\(completed)", "checkmark.circle.fill")
        }
    }
    func kpi(_ t: String, _ v: String, _ sf: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: sf).font(.title2)
            Text(v).font(.title3).bold()
            Text(t).font(.caption).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(RoundedRectangle(cornerRadius: 12)
            .fill(Color(NSColor.controlBackgroundColor)))
    }
    var taskTotalChart: some View {
        VStack(alignment: .leading) {
            Text("タスク別作業時間").font(.headline)
            ForEach(tasks) { t in
                TaskTotalRow(task: t, maxSeconds: tasks.first?.totalSeconds ?? 1)
            }
        }
    }
    func refreshSummaries() async {
        let result = await store.summaries(forDays: period.days)
        await MainActor.run { summaries = result }
    }
}

private struct TaskTotalRow: View {
    let task: TaskUsageSummary; let maxSeconds: Double
    var body: some View {
        HStack {
            Text(task.taskName).frame(width: 120, alignment: .leading)
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.accentColor.opacity(0.7))
                    .frame(width: maxSeconds > 0 ? geo.size.width * task.totalSeconds / maxSeconds : 0,
                                               height: 18)
            }
            .frame(height: 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(task.totalSeconds.hmString).frame(width: 70, alignment: .trailing)
        }
    }
}

private struct TaskStackedRow: View {
    let task: TaskUsageSummary
    let palette: [Color]
    
    private var segments: [Segment] {
        let total = max(task.totalSeconds, 1)
        return task.appBreakdown.enumerated().map { idx, app in
            Segment(color: palette[idx % palette.count],
                    name: app.name,
                    ratio: app.seconds / total)
        }
    }
    
    fileprivate struct Segment: Identifiable {
        let id = UUID()
        let color: Color
        let name: String
        let ratio: Double
    }
    
    private let minLabelWidth: CGFloat = 40
    private let barHeight: CGFloat = 18
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(task.taskName).font(.subheadline)
            
            GeometryReader { geo in
                HStack(spacing: 0) {
                    ForEach(segments) { seg in
                        SegmentBlock(segment: seg,
                                     width: geo.size.width * seg.ratio,
                                     minLabelWidth: minLabelWidth,
                                     barHeight: barHeight)
                    }
                }
            }
            .frame(height: barHeight)
            .frame(maxWidth: .infinity)
            
            Text(task.totalSeconds.hmString)
                .font(.caption2).foregroundColor(.secondary)
        }
    }
}

private struct SegmentBlock: View {
    let segment: TaskStackedRow.Segment
    let width: CGFloat
    let minLabelWidth: CGFloat
    let barHeight: CGFloat
    
    var body: some View {
        ZStack {
            segment.color
            if width >= minLabelWidth {
                Text(segment.name.prefix(10))
                    .font(.caption2).foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
        }
        .frame(width: max(width, 3), height: barHeight)
    }
}


private struct TaskAppStackedChartView: View {
    let tasks: [TaskUsageSummary]
    let overall: [(name: String, ratio: Double)]
    let palette: [Color]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("タスク内アプリ比率").font(.headline)
            
            OverallAppUsageBarView(usages: overall,
                                   palette: palette)
                .frame(height: 22)
                .frame(maxWidth: .infinity)
            
            ForEach(tasks) { TaskStackedRow(task: $0, palette: palette) }
        }
    }
}

private struct CompletionLineChartView: View {
    let points: [Int]; let maxValue: Int
    var body: some View {
        VStack(alignment: .leading) {
            Text("完了タスク推移").font(.headline)
            GeometryReader { geo in
                let cg = makePoints(size: geo.size)
                Path { p in guard let f = cg.first else { return }; p.move(to: f)
                    cg.dropFirst().forEach { p.addLine(to: $0) } }
                    .stroke(Color.accentColor, lineWidth: 2)
                ForEach(cg.indices, id: \.self) {
                    Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                        .position(cg[$0])
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
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    ForEach(Array(usages.enumerated()), id: \.offset) { idx, u in
                        let width = geo.size.width * CGFloat(u.ratio)
                        Rectangle()
                            .fill(palette[idx % palette.count])
                            .frame(width: width)
                            .overlay(
                                width >= 40 ?
                                Text("\(String(u.name.prefix(10))) \(Int(u.ratio * 100))%")
                                    .font(.caption2).foregroundColor(.white)
                                : nil
                            )
                    }
                }
            }
            .frame(height: 18)
        }
    }
}

private extension TimeInterval {
    var hmString: String {
        "\(Int(self) / 3600)h \((Int(self) % 3600) / 60)m"
    }
}

//#if DEBUG
//struct ManagementView_Previews: PreviewProvider {
//    static var previews: some View {
//        ManagementView().frame(width: 800, height: 1000)
//    }
//}
//#endif


