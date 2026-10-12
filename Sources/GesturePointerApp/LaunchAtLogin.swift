#if canImport(AppKit)
import Foundation
import ServiceManagement

/// Launch at login via `SMAppService.mainApp` (macOS 13+): no helper app, and the user can
/// see and revoke it in System Settings → General → Login Items.
///
/// The truth lives in the system, not in UserDefaults: the user can flip it in System Settings
/// at any time, and a change can fail or need approval. So the published value is always
/// re-read from `SMAppService` after an attempt, never assumed from what was asked for.
@MainActor
final class LaunchAtLoginModel: ObservableObject {
    enum Outcome {
        case changed
        /// Registered, but the user must allow it in System Settings → Login Items.
        case needsApproval
        case failed(String)
    }

    @Published private(set) var isEnabled = false

    init() { refresh() }

    /// Re-read the system state. Assigning always publishes, even when the value is the same,
    /// so a toggle that optimistically flipped snaps back after a failed change.
    func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func set(_ enabled: Bool) -> Outcome {
        defer { refresh() }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            return .failed(error.localizedDescription)
        }
        if enabled && SMAppService.mainApp.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
            return .needsApproval
        }
        return .changed
    }
}
#endif
