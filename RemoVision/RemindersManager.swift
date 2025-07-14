import Observation
import EventKit
import SwiftUI

@Observable
@MainActor
class RemindersManager {

    var taskLists: [String] = []
    var tasks: [TaskItem]  = []
    var selectedList: String = ""
    var accessStatus: ReminderAccessStatus = .unknown

    let store = EKEventStore()
    
    var errorMessage: String? = nil
    var showError: Bool = false

    init() {
        
    }

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

    private func refreshAccessAndLists() async {
    #if compiler(>=5.9)
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
    
    func requestAccess() async {
#if DEBUG
        print("🔍 リマインダー権限リクエストが呼ばれました")
        print("呼び出し元:")
        Thread.callStackSymbols.prefix(10).forEach { print($0) }
#endif
        let status = EKEventStore.authorizationStatus(for: .reminder)
        
        switch status {
        case .notDetermined:
            let granted = await requestFullAccessAsync()
            accessStatus = granted ? .authorized : .denied
            if granted {
                await fetchReminderLists()
            } else {
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: Notification.Name("ReminderAccessDenied"),
                        object: nil
                    )
                }
            }
        case .authorized:
            accessStatus = .authorized
            await fetchReminderLists()
        case .denied, .restricted:
            accessStatus = .denied
            await MainActor.run {
                NotificationCenter.default.post(
                    name: Notification.Name("ReminderAccessDenied"),
                    object: nil
                )
            }
        default:
            break
        }
    }

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

    func fetchReminderLists() async {
        let calendars = store.calendars(for: .reminder)
        guard !calendars.isEmpty else {
            accessStatus = .noLists
            taskLists    = []
            return
        }

        taskLists = calendars.map(\.title)

        guard let first = taskLists.first else { return }
        selectedList = first
        await fetchTasksAsync(for: first)
    }

    private func fetchTasksAsync(for listName: String) async {
        guard let calendar = store.calendars(for: .reminder).first(where: { $0.title == listName }) else {
            tasks = []
            accessStatus = .noLists
            return
        }

        let predicate = store.predicateForReminders(in: [calendar])

        do {
    #if compiler(>=5.9) && canImport(EventKit) && (!os(macOS) || targetEnvironment(macCatalyst) || swift(>=6.0))
            let ekReminders = try await store.reminders(matching: predicate)
    #else
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
            tasks = []
            accessStatus = .unknown
        }
    }

    func fetchTasks(for listName: String,
                    completion: @escaping ([TaskItem]) -> Void = { _ in }) {
        Task {
            await fetchTasksAsync(for: listName)
            completion(tasks)
        }
    }
    
    private func showErrorAlert(_ message: String) {
        errorMessage = message
        showError = true
    }

    func addTask(title: String) {
        guard let calendar = store.calendars(for: .reminder).first(where: { $0.title == selectedList }) else { return }
        let reminder = EKReminder(eventStore: store)
        reminder.title    = title
        reminder.calendar = calendar
        do {
            try store.save(reminder, commit: true)
            Task { await fetchTasksAsync(for: selectedList) }
        } catch {
            showErrorAlert("タスクを追加できませんでした: \(error.localizedDescription)")
        }
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
        } catch {
            showErrorAlert("タスクを更新できませんでした: \(error.localizedDescription)")
        }
    }

    func removeTask(_ task: TaskItem) {
        guard let reminder = store.calendarItem(withIdentifier: task.id) as? EKReminder else { return }
        do {
            try store.remove(reminder, commit: true)
            Task { await fetchTasksAsync(for: selectedList) }
        } catch {
            showErrorAlert("タスクを削除できませんでした: \(error.localizedDescription)")
        }
    }
    
    func renameTask(_ task: TaskItem, to newName: String) {
        guard let reminder = store.calendarItem(withIdentifier: task.id) as? EKReminder else { return }
        reminder.title = newName
        do {
            try store.save(reminder, commit: true)
            Task { await fetchReminderLists(); await fetchTasksAsync(for: selectedList) }
        } catch {
            showErrorAlert("タスク名を変更できませんでした: \(error.localizedDescription)")
        }
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

