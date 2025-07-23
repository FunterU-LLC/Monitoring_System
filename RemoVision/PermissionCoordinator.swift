import SwiftUI
import EventKit
import AVFoundation
import ApplicationServices

@Observable
@MainActor
final class PermissionCoordinator: NSObject {

    enum Status { case unknown, granted, denied }
    
    var remindersStatus:      Status = .unknown
    var cameraStatus:         Status = .unknown
    var accessibilityStatus:  Status = .unknown

    private let eventStore = EKEventStore()

    func requestInitialPermissions() async {
        await requestReminders()
        await requestCamera()
        recheckAccessibility()
    }

    func requestReminders() async {
#if compiler(>=5.9)
        let granted = await withCheckedContinuation { cont in
            eventStore.requestFullAccessToReminders { ok, _ in cont.resume(returning: ok) }
        }
#else
        let granted = await withCheckedContinuation { cont in
            eventStore.requestAccess(to: .reminder) { ok, _ in cont.resume(returning: ok) }
        }
#endif
        remindersStatus = granted ? .granted : .denied
    }

    func requestCamera() async {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        cameraStatus = granted ? .granted : .denied
    }

    func promptAccessibilityPanel() {
        let opt: [String: Any] = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ]
        _ = AXIsProcessTrustedWithOptions(opt as CFDictionary)
        recheckAccessibility()
    }

    func recheckAll() {
        recheckReminders()
        recheckCamera()
        recheckAccessibility()
    }

    private func recheckReminders() {
        let freshEventStore = EKEventStore()
        
        #if compiler(>=5.9)
        Task { @MainActor in
            do {
                let status = try await freshEventStore.requestFullAccessToReminders()
                remindersStatus = status ? .granted : .denied
            } catch {
                checkRemindersLegacy()
            }
        }
        #else
        checkRemindersLegacy()
        #endif
    }

    private func checkRemindersLegacy() {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .authorized, .fullAccess, .writeOnly:
            remindersStatus = .granted
        case .notDetermined:
            remindersStatus = .unknown
        default:
            remindersStatus = .denied
        }
    }

    private func recheckCamera() {
        cameraStatus = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
            ? .granted : .denied
    }

    public func recheckAccessibility() {
        accessibilityStatus = AXIsProcessTrusted() ? .granted : .denied
    }

    var allGranted: Bool {
        [remindersStatus, cameraStatus, accessibilityStatus].allSatisfy { $0 == .granted }
    }
}
