import Foundation
import Network

actor SupabaseManager {

    static let shared = SupabaseManager()

    private let monitor      = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "NetworkMonitorQueue")

    private var isOnline: Bool = false

    private var attendanceLogBuffer: [AttendanceLog] = []
    private var appUsageLogBuffer:  [AppUsageLog]    = []

    private var syncTask: Task<Void, Never>? = nil

private init() {
    Task { [weak self] in
        guard let self else { return }
        await self.startNetworkMonitor()
        await self.startSyncLoop()
    }
}
    deinit {
        monitor.cancel()
        syncTask?.cancel()
    }

    func currentOnlineStatus() -> Bool { isOnline }

    func sendAttendanceLog(_ log: AttendanceLog) async {
        if isOnline {
            print("Sending attendance log to Supabase immediately: \(log)")
        } else {
            attendanceLogBuffer.append(log)
            print("Offline: attendance log buffered: \(log)")
        }
    }

    func sendAppUsageLogs(_ logs: [AppUsageLog]) async {
        if isOnline {
            print("Sending \(logs.count) app usage logs to Supabase immediately.")
        } else {
            appUsageLogBuffer.append(contentsOf: logs)
            print("Offline: app usage logs buffered. Count=\(logs.count)")
        }
    }

    func fetchReports() async {
        if isOnline {
            print("Fetch reports from Supabase.")
        } else {
            print("Cannot fetch reports (offline).")
        }
    }

    private func startNetworkMonitor() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { [weak self] in
                guard let self else { return }
                let wasOnline = await self.isOnline
                await self.setOnline(path.status == .satisfied)
                if await self.isOnline && !wasOnline {
                    await self.syncOfflineData()
                }
            }
        }
        monitor.start(queue: monitorQueue)
    }

    private func setOnline(_ value: Bool) {
        isOnline = value
    }

    private func startSyncLoop() {
        syncTask?.cancel()
        syncTask = Task.detached { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await self.syncOfflineData()
            }
        }
    }

    private func syncOfflineData() async {
        guard isOnline else { return }

        if !attendanceLogBuffer.isEmpty {
            print("Syncing offline attendance logs. Count=\(attendanceLogBuffer.count)")
            attendanceLogBuffer.removeAll()
        }
        if !appUsageLogBuffer.isEmpty {
            print("Syncing offline app usage logs. Count=\(appUsageLogBuffer.count)")
            appUsageLogBuffer.removeAll()
        }
    }
}

