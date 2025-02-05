import Observation      // ← Combine は不要
import EventKit
import SwiftUI

@Observable
@MainActor
class RemindersManager {

    // ────────── 公開プロパティ ──────────
    var taskLists: [String] = []
    var tasks: [TaskItem]  = []
    var selectedList: String = ""
    var accessStatus: ReminderAccessStatus = .unknown

    private let store = EKEventStore()

    // MARK: - イニシャライザ
    init() {
        // 非同期で権限確認 → リスト取得
        Task { await refreshAccessAndLists() }
    }

    // MARK: - アクセス状態
    enum ReminderAccessStatus {
        case authorized, denied, noLists, noTasks, unknown

        var message: String {
            switch self {
            case .authorized: return ""
            case .denied:     return "リマインダーへのアクセスが拒否されています。設定アプリで権限を許可してください。"
            case .noLists:    return "リマインダーリストが見つかりませんでした。リマインダーアプリでリストを作成してください。"
            case .noTasks:    return "選択されたリストにタスクがありません。"
            case .unknown:    return "リマインダーの読み込み中にエラーが発生しました。"
            }
        }
    }

    // MARK: - 権限確認 & リスト取得（async）
    // MARK: - 権限確認 & リスト取得（async）
    private func refreshAccessAndLists() async {
    #if compiler(>=5.9)
        // ────── 新 SDK (macOS14/iOS17 以降) ──────
        let status = EKEventStore.authorizationStatus(for: .reminder)

        switch status {
        case .authorized, .fullAccess, .writeOnly:
            accessStatus = .authorized
            await fetchReminderLists()

        case .denied, .restricted:
            accessStatus = .denied

        case .notDetermined:
            let granted = await requestFullAccessAsync()
            accessStatus = granted ? .authorized : .denied
            if granted { await fetchReminderLists() }

        @unknown default:
            let granted = await requestFullAccessAsync()
            accessStatus = granted ? .authorized : .denied
            if granted { await fetchReminderLists() }
        }

    #else
        // ────── 旧 SDK (macOS13/iOS16 以前) ──────
        let status = EKEventStore.authorizationStatus(for: .reminder)

        switch status {
        case .authorized:
            accessStatus = .authorized
            await fetchReminderLists()

        case .denied, .restricted:
            accessStatus = .denied

        case .notDetermined:
            let granted = await requestFullAccessAsync()
            accessStatus = granted ? .authorized : .denied
            if granted { await fetchReminderLists() }

        @unknown default:
            let granted = await requestFullAccessAsync()
            accessStatus = granted ? .authorized : .denied
            if granted { await fetchReminderLists() }
        }
    #endif
    }

    /// macOS 14/iOS 17 で追加されたフルアクセス要求を async ラップ
    private func requestFullAccessAsync() async -> Bool {
        await withCheckedContinuation { continuation in
#if compiler(>=5.9)
            store.requestFullAccessToReminders { granted, _ in
                continuation.resume(returning: granted)
            }
#else
            store.requestAccess(to: .reminder) { granted, _ in
                continuation.resume(returning: granted)
            }
#endif
        }
    }

    // MARK: - リスト取得（async）
    func fetchReminderLists() async {
        let calendars = store.calendars(for: .reminder)
        guard !calendars.isEmpty else {
            accessStatus = .noLists
            taskLists    = []
            return
        }

        taskLists = calendars.map(\.title)

        // デフォルト選択
        guard let first = taskLists.first else { return }
        selectedList = first
        await fetchTasksAsync(for: first)
    }

    // MARK: - タスク取得（async メインルーチン）
    // MARK: - タスク取得（async メインルーチン）
    private func fetchTasksAsync(for listName: String) async {
        guard let calendar = store.calendars(for: .reminder).first(where: { $0.title == listName }) else {
            tasks = []
            accessStatus = .noLists
            return
        }

        let predicate = store.predicateForReminders(in: [calendar])

        do {
    #if compiler(>=5.9) && canImport(EventKit) && (!os(macOS) || targetEnvironment(macCatalyst) || swift(>=6.0))
            // 将来の SDK で利用可能になる async API
            let ekReminders = try await store.reminders(matching: predicate)
    #else
            // 旧 API fetchReminders を async ラップ
            let ekReminders = try await withCheckedThrowingContinuation { cont in
                store.fetchReminders(matching: predicate) { result in
                    if let result {
                        cont.resume(returning: result)
                    } else {
                        cont.resume(throwing: NSError(domain: "EKError", code: -1))
                    }
                }
            }
    #endif
            let incompleted = ekReminders.filter { !$0.isCompleted }
            tasks = incompleted.map {
                TaskItem(id: $0.calendarItemIdentifier,
                         title: $0.title,
                         dueDate: $0.dueDateComponents?.date,
                         isCompleted: $0.isCompleted,
                         notes: $0.notes)
            }
            accessStatus = tasks.isEmpty ? .noTasks : .authorized
        } catch {
            print("リマインダー取得失敗: \(error)")
            tasks = []
            accessStatus = .unknown
        }
    }

    // MARK: - 旧インターフェース互換ラッパー
    /// 既存ビュー用：非同期で取得後に completion に返す
    func fetchTasks(for listName: String,
                    completion: @escaping ([TaskItem]) -> Void = { _ in }) {
        Task {
            await fetchTasksAsync(for: listName)
            completion(tasks)
        }
    }

    // MARK: - CRUD
    func addTask(title: String) {
        guard let calendar = store.calendars(for: .reminder).first(where: { $0.title == selectedList }) else { return }
        let reminder = EKReminder(eventStore: store)
        reminder.title    = title
        reminder.calendar = calendar
        do {
            try store.save(reminder, commit: true)
            Task { await fetchTasksAsync(for: selectedList) }
        } catch { print("Failed to add reminder: \(error)") }
    }

    func updateTask(_ task: TaskItem, completed: Bool, notes: String?) {
        guard let reminder = store.calendarItem(withIdentifier: task.id) as? EKReminder else { return }
        reminder.isCompleted = completed
        if let notes {
            reminder.notes = (reminder.notes ?? "") + (reminder.notes == nil ? "" : "\n") + notes
        }
        do {
            try store.save(reminder, commit: true)
            Task { await fetchTasksAsync(for: selectedList) }
        } catch { print("Failed to update reminder: \(error)") }
    }

    func removeTask(_ task: TaskItem) {
        guard let reminder = store.calendarItem(withIdentifier: task.id) as? EKReminder else { return }
        do {
            try store.remove(reminder, commit: true)
            Task { await fetchTasksAsync(for: selectedList) }
        } catch { print("Failed to remove reminder: \(error)") }
    }
}

#if DEBUG
struct RemindersManager_Previews: PreviewProvider {
    static var previews: some View {
        Text("RemindersManagerのプレビュー")
            .frame(width: 300, height: 100)
            .environment(RemindersManager())
    }
}
#endif

