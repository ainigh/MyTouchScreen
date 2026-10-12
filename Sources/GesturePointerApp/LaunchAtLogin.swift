#if canImport(AppKit)
import Foundation
import ServiceManagement

/// Launch at login via `SMAppService.mainApp` (macOS 13+): no helper app, and the user can
/// see and revoke it in System Settings → General → Login Items.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
#endif
