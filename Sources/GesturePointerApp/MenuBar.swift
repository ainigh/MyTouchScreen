#if canImport(AppKit)
import AppKit
import GestureCore

/// What the menu-bar icon shows.
enum MenuBarStatus: Equatable {
    case off
    case standby
    case engaged
    case needsPermission
}

/// Actions the menu can trigger; implemented by AppController.
@MainActor
protocol MenuBarActions: AnyObject {
    var menuStatus: MenuBarStatus { get }
    var isEnabled: Bool { get }
    var isRecording: Bool { get }
    var cameras: [CameraInfo] { get }
    var selectedCameraID: String? { get }
    var showsPreview: Bool { get }
    var launchesAtLogin: Bool { get }
    var hotkeyDisplay: String { get }
    var versionLine: String { get }
    var updateState: Updater.State { get }
    func toggleEnabled()
    func toggleEngaged()
    func selectCamera(_ id: String?)
    func startCalibration()
    func togglePreview()
    func toggleLaunchAtLogin()
    func toggleRecording()
    func showSettings()
    func showWelcome()
    func checkForUpdates()
    func installUpdate()
    func copyUpdateError()
    func quit()
}

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private weak var actions: MenuBarActions?

    init(actions: MenuBarActions) {
        self.actions = actions
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        statusItem.button?.toolTip = "Wisp"
        update(status: actions.menuStatus)
    }

    func update(status: MenuBarStatus) {
        let symbol: String
        let description: String
        switch status {
        case .off:
            symbol = "hand.raised.slash"
            description = "Wisp is off"
        case .standby:
            symbol = "hand.point.up.left"
            description = "Wisp is on standby"
        case .engaged:
            symbol = "hand.point.up.left.fill"
            description = "Wisp is engaged"
        case .needsPermission:
            symbol = "exclamationmark.triangle"
            description = "Wisp needs permission"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = description
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let actions else { return }

        let statusLine: String
        switch actions.menuStatus {
        case .off: statusLine = "Off"
        case .standby: statusLine = "Standby — raise an open palm or press \(actions.hotkeyDisplay)"
        case .engaged: statusLine = "Engaged — point, pinch to click"
        case .needsPermission: statusLine = "Needs permission — open Setup…"
        }
        let header = NSMenuItem(title: statusLine, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        menu.addItem(item(actions.isEnabled ? "Turn Wisp Off" : "Turn Wisp On", #selector(toggleEnabled)))
        let engage = item(actions.menuStatus == .engaged ? "Disengage" : "Engage", #selector(toggleEngaged))
        engage.isEnabled = actions.isEnabled
        menu.addItem(engage)
        menu.addItem(.separator())

        let cameraItem = NSMenuItem(title: "Camera", action: nil, keyEquivalent: "")
        let cameraMenu = NSMenu()
        let automatic = item("Automatic (prefer iPhone)", #selector(selectCamera(_:)))
        automatic.representedObject = nil
        automatic.state = actions.selectedCameraID == nil ? .on : .off
        cameraMenu.addItem(automatic)
        for camera in actions.cameras {
            let entry = item(camera.name, #selector(selectCamera(_:)))
            entry.representedObject = camera.id
            entry.state = actions.selectedCameraID == camera.id ? .on : .off
            cameraMenu.addItem(entry)
        }
        cameraItem.submenu = cameraMenu
        menu.addItem(cameraItem)
        menu.addItem(item("Calibrate This Display…", #selector(calibrate)))
        let preview = item("Show Camera Preview", #selector(togglePreview))
        preview.state = actions.showsPreview ? .on : .off
        menu.addItem(preview)
        menu.addItem(item(actions.isRecording ? "Stop Recording Session" : "Record Session for Tuning", #selector(toggleRecording)))
        menu.addItem(.separator())

        menu.addItem(item("Settings…", #selector(showSettings), key: ","))
        menu.addItem(item("Setup & Permissions…", #selector(showWelcome)))
        let login = item("Launch at Login", #selector(toggleLaunchAtLogin))
        login.state = actions.launchesAtLogin ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        addUpdateItems(actions)
        menu.addItem(.separator())
        menu.addItem(item("Quit Wisp", #selector(quit), key: "q"))
    }

    private func addUpdateItems(_ actions: MenuBarActions) {
        let version = NSMenuItem(title: actions.versionLine, action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)
        switch actions.updateState {
        case .idle, .upToDate:
            menu.addItem(item("Check for Updates…", #selector(checkForUpdates)))
        case .checking:
            let checking = item("Checking for Updates…", #selector(checkForUpdates))
            checking.isEnabled = false
            menu.addItem(checking)
        case .available(let plan):
            let title: String
            switch plan {
            case let .prebuilt(commit, release): title = "Update to \(release.tag) — \(commit.title)"
            case let .buildHere(commit): title = "Update (build here) — \(commit.short): \(commit.title)"
            case .upToDate: title = "Check for Updates…"
            }
            let update = item(title, #selector(installUpdate))
            update.toolTip = "Downloads the new version (or builds it on this Mac when GitHub hasn't), then restarts Wisp."
            menu.addItem(update)
        case .installing(let step):
            let progress = item(step, #selector(installUpdate))
            progress.isEnabled = false
            menu.addItem(progress)
        case .failed(let message):
            let failed = NSMenuItem(title: message, action: nil, keyEquivalent: "")
            failed.isEnabled = false
            menu.addItem(failed)
            menu.addItem(item("Copy Update Details", #selector(copyUpdateError)))
            menu.addItem(item("Check for Updates…", #selector(checkForUpdates)))
        }
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.isEnabled = true
        return item
    }

    // MARK: Actions

    @objc private func toggleEnabled() { actions?.toggleEnabled() }
    @objc private func toggleEngaged() { actions?.toggleEngaged() }
    @objc private func selectCamera(_ sender: NSMenuItem) { actions?.selectCamera(sender.representedObject as? String) }
    @objc private func calibrate() { actions?.startCalibration() }
    @objc private func togglePreview() { actions?.togglePreview() }
    @objc private func toggleRecording() { actions?.toggleRecording() }
    @objc private func showSettings() { actions?.showSettings() }
    @objc private func showWelcome() { actions?.showWelcome() }
    @objc private func toggleLaunchAtLogin() { actions?.toggleLaunchAtLogin() }
    @objc private func checkForUpdates() { actions?.checkForUpdates() }
    @objc private func installUpdate() { actions?.installUpdate() }
    @objc private func copyUpdateError() { actions?.copyUpdateError() }
    @objc private func quit() { actions?.quit() }
}
#endif
