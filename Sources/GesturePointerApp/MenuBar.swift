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
    /// The gesture settings, for the presets submenus.
    var gestureConfig: GestureConfig { get }
    var showsPreview: Bool { get }
    var launchesAtLogin: Bool { get }
    var hotkeyDisplay: String { get }
    /// One line on how to use the current input model ("point, tap to click").
    var engagedHint: String { get }
    var versionLine: String { get }
    var updateState: Updater.State { get }
    func toggleEnabled()
    func toggleEngaged()
    func selectCamera(_ id: String?)
    func updateGestureConfig(_ change: (inout GestureConfig) -> Void)
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

/// One entry of a presets submenu.
private struct PresetChoice {
    var title: String
    var tip: String
    var tag: String
    var isOn: Bool
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
        // Populate once up front: a status item whose menu is empty may not open at all, and
        // then menuNeedsUpdate would never get a chance to fill it.
        menuNeedsUpdate(menu)
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
        case .standby: statusLine = "Standby — raise both open palms or press \(actions.hotkeyDisplay)"
        case .engaged: statusLine = "Engaged — \(actions.engagedHint)"
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
        let config = actions.gestureConfig
        menu.addItem(presetMenu("Cursor Speed", PointerResponse.allCases.map {
            PresetChoice(title: $0.title, tip: $0.summary, tag: "speed:" + $0.rawValue, isOn: config.pointerResponse == $0)
        }))
        let assist = item("Target Assist", #selector(toggleTargetAssist))
        assist.state = config.assist.enabled ? .on : .off
        assist.toolTip = "Slow down near buttons and links, and pull a stopping cursor onto them. Tune it in Settings → Targets."
        menu.addItem(assist)
        menu.addItem(presetMenu("Click", ClickGesture.allCases.map {
            PresetChoice(title: $0.title, tip: $0.summary, tag: "click:" + $0.rawValue, isOn: config.clickGesture == $0)
        }))
        menu.addItem(presetMenu("Drag", DragGesture.allCases.map {
            PresetChoice(title: $0.title, tip: $0.summary, tag: "drag:" + $0.rawValue, isOn: config.dragGesture == $0)
        }))
        menu.addItem(presetMenu("Zoom", ZoomGesture.allCases.map {
            PresetChoice(title: $0.title, tip: $0.summary, tag: "zoom:" + $0.rawValue, isOn: config.zoomGesture == $0)
        }))
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
    /// A preset submenu entry's tag is "kind:rawValue".
    @objc private func selectPreset(_ sender: NSMenuItem) {
        guard let tag = sender.representedObject as? String, let colon = tag.firstIndex(of: ":") else { return }
        let kind = String(tag[..<colon])
        let raw = String(tag[tag.index(after: colon)...])
        actions?.updateGestureConfig { config in
            switch kind {
            case "speed": if let v = PointerResponse(rawValue: raw) { config.pointerResponse = v }
            case "click": if let v = ClickGesture(rawValue: raw) { config.clickGesture = v }
            case "drag": if let v = DragGesture(rawValue: raw) { config.dragGesture = v }
            case "zoom": if let v = ZoomGesture(rawValue: raw) { config.zoomGesture = v }
            default: break
            }
        }
    }

    /// A submenu of mutually exclusive presets (the chosen one is checked).
    private func presetMenu(_ title: String, _ choices: [PresetChoice]) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for choice in choices {
            let entry = item(choice.title, #selector(selectPreset(_:)))
            entry.representedObject = choice.tag
            entry.toolTip = choice.tip
            entry.state = choice.isOn ? .on : .off
            submenu.addItem(entry)
        }
        parent.submenu = submenu
        return parent
    }

    @objc private func toggleTargetAssist() { actions?.updateGestureConfig { $0.assist.enabled.toggle() } }
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
