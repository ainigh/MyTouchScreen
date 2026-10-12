#if canImport(AppKit)
import AppKit

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
    func toggleEnabled()
    func toggleEngaged()
    func selectCamera(_ id: String?)
    func startCalibration()
    func togglePreview()
    func toggleLaunchAtLogin()
    func toggleRecording()
    func showSettings()
    func showWelcome()
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
        menu.addItem(item("Quit Wisp", #selector(quit), key: "q"))
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
    @objc private func quit() { actions?.quit() }
}
#endif
