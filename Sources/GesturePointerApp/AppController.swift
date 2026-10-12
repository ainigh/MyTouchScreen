#if canImport(AppKit)
import AppKit
import AVFoundation
import CoreMedia
import GestureCore
import QuartzCore
import SwiftUI

/// Wires the app together and owns all main-thread state.
///
/// Threads, end to end:
/// camera frame queue (Vision) → pipeline queue (state machine, CGEvent posting)
/// → main queue (overlay, menu, sounds). Nothing on the camera or pipeline queues waits for
/// the main thread, so UI work can never add latency to the cursor.
@MainActor
final class AppController: MenuBarActions {
    private enum CameraMode { case off, standby, full }

    private let options: LaunchOptions
    private let settings: AppSettings
    private let camera = Camera()
    private let tracker = HandTracker()
    private let pipeline: GesturePipeline
    private let sounds = Sounds()
    private let hotkey = GlobalHotkey()
    private let permissionMonitor = PermissionMonitor()
    private let updater = Updater()
    private var userCheckedForUpdates = false
    private var announcedUpdate: UpdatePlan?

    private var overlay: OverlayController?
    private var menuBar: MenuBarController?
    private var preview: PreviewPanel?
    private var calibration: CalibrationController?
    private var welcomeWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var replayer: Replayer?

    private var cameraMode: CameraMode = .off
    private var engaged = false
    private var lastSnapshot = PointerSnapshot()
    private var lastStatus: MenuBarStatus = .off
    private var mouseMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var statusTimer: Timer?
    private var recordingURL: URL?
    private var lastTakeoverToast: Double = 0
    private var registeredHotkey: HotkeyCombo?
    private var configuredCamera: (id: String?, resolution: CameraResolution)?
    private var appliedConfig: (config: GestureConfig, zoomStyle: ZoomStyle)?
    private var appliedCalibration: CalibrationSet?
    private var activeCameraName = ""
    private var activeCameraFPS = 0.0
    private var axGranted = Permissions.accessibilityGranted

    init(options: LaunchOptions) {
        self.options = options
        let settings = AppSettings()
        self.settings = settings
        pipeline = GesturePipeline(config: settings.config, displays: Displays.current(),
                                   calibration: settings.calibration, synth: InputSynth())
    }

    // MARK: Lifecycle

    func start() {
        pipeline.configureOutput(postsEvents: !options.dryRun, logsIntents: options.dryRun,
                                 printsFrames: options.noOverlay)
        pipeline.onUpdate = { [weak self] snapshot, events in
            self?.handleUpdate(snapshot, events)
        }

        camera.onFrame = Self.makeFrameHandler(tracker: tracker, pipeline: pipeline)
        camera.onError = { [weak self] message in
            self?.overlay?.toast(message, symbol: "video.slash", tint: Theme.warning)
            if self?.options.noOverlay == true { print("camera: \(message)") }
        }
        camera.onConfigured = { [weak self] info, fps in
            self?.activeCameraName = info.name
            self?.activeCameraFPS = fps
            if self?.options.noOverlay == true { print("camera: \(info.name) at \(Int(fps)) fps") }
        }

        hotkey.onPress = { [weak self] in self?.toggleEngaged() }
        settings.onChange = { [weak self] in self?.applySettings() }

        menuBar = MenuBarController(actions: self)
        if !options.noOverlay { overlay = OverlayController() }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.displaysChanged() }
        }
        statusTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermissionStatus() }
        }

        applySettings()

        updater.onChange = { [weak self] state in self?.updaterChanged(state) }

        if let path = options.replayPath {
            startReplay(path)
            return
        }
        if let path = options.recordPath {
            startRecording(to: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        }
        if !settings.hasCompletedOnboarding || Permissions.cameraState != .granted || !axGranted {
            showWelcome()
        }
        updateCameraMode()
        updater.start()
    }

    private func updaterChanged(_ state: Updater.State) {
        switch state {
        case .available(let plan):
            if announcedUpdate != plan || userCheckedForUpdates {
                announcedUpdate = plan
                overlay?.toast("Update available — see the menu", symbol: "arrow.down.circle")
            }
            userCheckedForUpdates = false
        case .upToDate:
            if userCheckedForUpdates {
                overlay?.toast("Wisp is up to date", symbol: "checkmark.circle.fill")
            }
            userCheckedForUpdates = false
        case .failed(let message):
            if userCheckedForUpdates {
                overlay?.toast(message, symbol: "exclamationmark.triangle.fill", tint: Theme.warning)
            }
            userCheckedForUpdates = false
        case .installing(let step):
            overlay?.toast(step, symbol: "arrow.down.circle")
        case .idle, .checking:
            break
        }
    }

    func shutdown() {
        pipeline.shutdown()
        camera.stop()
        hotkey.unregister()
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
    }

    /// Built outside the main actor on purpose: this closure runs on the camera's frame queue
    /// and must only touch the tracker and the pipeline, never UI state.
    nonisolated private static func makeFrameHandler(tracker: HandTracker, pipeline: GesturePipeline) -> (CMSampleBuffer) -> Void {
        return { sampleBuffer in
            if let frame = tracker.process(sampleBuffer, timestamp: CACurrentMediaTime()) {
                pipeline.submit(frame)
            }
        }
    }

    /// Wraps a main-actor frame handler for the pipeline queue: hops to main for each frame.
    nonisolated private static func mainHop(_ handler: @escaping (TrackingFrame) -> Void) -> (TrackingFrame) -> Void {
        return { frame in
            DispatchQueue.main.async { handler(frame) }
        }
    }

    // MARK: Settings

    private func applySettings() {
        // Only push real changes: re-applying a config resets the filters and scroll momentum,
        // which would visibly hitch a gesture whenever an unrelated setting (preview corner) moves.
        if appliedConfig?.config != settings.config || appliedConfig?.zoomStyle != settings.zoomStyle {
            appliedConfig = (settings.config, settings.zoomStyle)
            pipeline.update(config: settings.config, zoomStyle: settings.zoomStyle)
        }
        if appliedCalibration != settings.calibration {
            appliedCalibration = settings.calibration
            pipeline.update(calibration: settings.calibration)
        }
        sounds.enabled = settings.soundsEnabled
        overlay?.showStatusGlyph = settings.showStatusGlyph

        if registeredHotkey != settings.hotkey {
            if hotkey.register(settings.hotkey) {
                registeredHotkey = settings.hotkey
            } else {
                registeredHotkey = nil
                overlay?.toast("\(settings.hotkey.displayString) is taken by another app", symbol: "keyboard",
                               tint: Theme.warning)
            }
        }

        // Only touch the camera once access is granted: opening a device input earlier would
        // pop the system prompt at launch, before the welcome window explains why.
        let wantedCamera = (id: settings.cameraID, resolution: settings.resolution)
        if Permissions.cameraState == .granted,
           configuredCamera?.id != wantedCamera.id || configuredCamera?.resolution != wantedCamera.resolution {
            configuredCamera = wantedCamera
            camera.configure(deviceID: wantedCamera.id, resolution: wantedCamera.resolution)
        }

        if !settings.enabled && engaged {
            pipeline.setEngaged(false, reason: .menu)
        }
        updatePreview()
        updateCameraMode()
        updateStatus()
    }

    private func updatePreview() {
        let wanted = settings.showPreview && settings.enabled && Permissions.cameraState == .granted
            && !options.noOverlay && options.replayPath == nil
        if wanted && preview == nil {
            let panel = PreviewPanel(session: camera.session, corner: settings.previewCorner)
            panel.onCornerChange = { [weak self] corner in self?.settings.previewCorner = corner }
            panel.show()
            preview = panel
        } else if !wanted, let panel = preview {
            panel.close()
            preview = nil
        }
        preview?.showsSkeleton = settings.showSkeleton
    }

    // MARK: Camera power

    private func desiredCameraMode() -> CameraMode {
        guard options.replayPath == nil, Permissions.cameraState == .granted else { return .off }
        if calibration != nil || engaged { return .full }
        guard settings.enabled else { return .off }
        // Standby watches for the engage palm (and feeds the preview) at a few fps.
        if settings.config.palmEngageEnabled || settings.showPreview { return .standby }
        return .off
    }

    private func updateCameraMode() {
        let mode = desiredCameraMode()
        guard mode != cameraMode else { return }
        let previous = cameraMode
        cameraMode = mode
        let tracker = tracker
        switch mode {
        case .off:
            camera.stop()
            if previous != .off && settings.enabled {
                overlay?.toast("Camera paused", symbol: "video.slash", tint: Theme.idle)
            }
        case .standby:
            camera.frameQueue.async { tracker.minimumInterval = 1.0 / 8.0 }
            camera.start()
        case .full:
            camera.frameQueue.async { tracker.minimumInterval = 0 }
            camera.start()
        }
    }

    // MARK: Pipeline updates

    private func handleUpdate(_ snapshot: PointerSnapshot, _ events: [PointerEvent]) {
        lastSnapshot = snapshot
        for event in events { handle(event, snapshot: snapshot) }
        overlay?.update(snapshot, status: menuStatus)
        preview?.update(hands: snapshot.hands, primaryIndex: snapshot.primaryHandIndex)
        updateStatus()
    }

    private func handle(_ event: PointerEvent, snapshot: PointerSnapshot) {
        if options.noOverlay || options.replayPath != nil { print("event: \(event)") }
        switch event {
        case .engaged:
            engaged = true
            sounds.play(.engage)
            if axGranted {
                overlay?.toast("Engaged", symbol: "hand.point.up.left.fill")
            } else {
                overlay?.toast("Accessibility permission needed", symbol: "exclamationmark.triangle.fill",
                               tint: Theme.warning)
            }
            installMouseMonitor()
            updateCameraMode()
        case .disengaged(let reason):
            engaged = false
            sounds.play(.disengage)
            let text = reason == .handLost ? "Hand lost — standing by" : "Standing by"
            overlay?.toast(text, symbol: "hand.raised", tint: Theme.idle)
            removeMouseMonitor()
            updateCameraMode()
        case .clicked, .rightClicked, .dwellClicked:
            sounds.play(.click)
        case .dragStarted:
            sounds.play(.dragStart)
        case .dragEnded:
            sounds.play(.drop)
        case .scrollEnded:
            if snapshot.momentumActive { sounds.play(.scrollFade) }
        case .externalMouseTookOver:
            let now = CACurrentMediaTime()
            if now - lastTakeoverToast > 10 {
                lastTakeoverToast = now
                overlay?.toast("Mouse in control", symbol: "computermouse", tint: Theme.idle)
            }
        case .scrollStarted, .zoomStarted, .zoomEnded, .appSwitcherOpened, .appSwitcherClosed, .displayChanged:
            break
        }
    }

    // MARK: Real mouse

    private func installMouseMonitor() {
        guard mouseMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                                           .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.handleMouseEvent(event) }
        }
    }

    private func removeMouseMonitor() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
    }

    /// The user touched the real mouse or trackpad: tell the pipeline, which pauses hand output.
    private func handleMouseEvent(_ event: NSEvent) {
        guard let cgEvent = event.cgEvent else { return }
        if cgEvent.getIntegerValueField(.eventSourceUserData) == InputSynth.eventMarker { return }
        let location = cgEvent.location
        if event.type != .scrollWheel && pipeline.synth.isOwnEvent(at: location) { return }
        pipeline.noteExternalMouse(at: location)
    }

    // MARK: Displays and permissions

    private func displaysChanged() {
        pipeline.update(displays: Displays.current())
        overlay?.rebuild()
    }

    private func refreshPermissionStatus() {
        if Permissions.cameraState == .granted && configuredCamera == nil {
            configuredCamera = (id: settings.cameraID, resolution: settings.resolution)
            camera.configure(deviceID: settings.cameraID, resolution: settings.resolution)
        }
        let ax = Permissions.accessibilityGranted
        if ax != axGranted {
            axGranted = ax
            if ax { overlay?.toast("Accessibility granted", symbol: "checkmark.circle.fill") }
        }
        updatePreview()
        updateCameraMode()
        updateStatus()
    }

    private func updateStatus() {
        let status = menuStatus
        if status != lastStatus {
            lastStatus = status
            menuBar?.update(status: status)
        }
    }

    // MARK: Replay and recording

    private func startReplay(_ path: String) {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        do {
            let recording = try Recording.load(from: url)
            print(String(format: "Replaying %d frames (%.1f s) from %@", recording.frames.count,
                         recording.duration, url.path))
            pipeline.setEngaged(true, reason: .hotkey)
            let replayer = Replayer()
            self.replayer = replayer
            replayer.play(recording, into: pipeline) { count in
                print("Replay finished: \(count) frames.")
                NSApp.terminate(nil)
            }
        } catch {
            print("error: couldn't read \(url.path): \(error.localizedDescription)")
            NSApp.terminate(nil)
        }
    }

    private func startRecording(to url: URL) {
        let info: [String: String] = [
            "app": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
            "camera": activeCameraName,
            "cameraFPS": String(format: "%.0f", activeCameraFPS),
            "recordedAt": ISO8601DateFormatter().string(from: Date()),
            "config": (try? String(data: JSONEncoder().encode(settings.config), encoding: .utf8) ?? "") ?? "",
        ]
        do {
            try pipeline.startRecording(to: url, info: info)
            recordingURL = url
            overlay?.toast("Recording session", symbol: "record.circle", tint: Theme.warning)
            if options.noOverlay { print("recording to \(url.path)") }
        } catch {
            overlay?.toast("Can't record: \(error.localizedDescription)", symbol: "xmark.octagon", tint: Theme.warning)
            print("error: can't record to \(url.path): \(error.localizedDescription)")
        }
    }

    // MARK: Windows

    func showWelcome() {
        if let welcomeWindow {
            welcomeWindow.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let view = WelcomeView(
            monitor: permissionMonitor, settings: settings, cameras: Camera.availableCameras(),
            onCalibrate: { [weak self] in
                self?.finishOnboarding()
                self?.startCalibration()
            },
            onFinish: { [weak self] in
                self?.finishOnboarding()
                self?.overlay?.toast("Raise an open palm to engage", symbol: "hand.raised")
            })
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Wisp Setup"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        welcomeWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func finishOnboarding() {
        settings.hasCompletedOnboarding = true
        welcomeWindow?.close()
        welcomeWindow = nil
        refreshPermissionStatus()
    }

    // MARK: MenuBarActions

    var menuStatus: MenuBarStatus {
        if Permissions.cameraState != .granted || !axGranted { return .needsPermission }
        if !settings.enabled { return .off }
        return engaged ? .engaged : .standby
    }

    var isEnabled: Bool { settings.enabled }
    var isRecording: Bool { recordingURL != nil }
    var cameras: [CameraInfo] { Camera.availableCameras() }
    var selectedCameraID: String? { settings.cameraID }
    var showsPreview: Bool { settings.showPreview }
    var launchesAtLogin: Bool { LaunchAtLogin.isEnabled }
    var hotkeyDisplay: String { settings.hotkey.displayString }
    var versionLine: String { updater.versionLine }
    var updateState: Updater.State { updater.state }

    func checkForUpdates() {
        userCheckedForUpdates = true
        updater.check(userInitiated: true)
    }

    func installUpdate() {
        // Never restart in the middle of a drag or with a modifier held.
        if engaged { pipeline.setEngaged(false, reason: .menu) }
        updater.install()
    }

    func copyUpdateError() {
        guard case .failed(let message) = updater.state else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Updater.report(message), forType: .string)
        overlay?.toast("Copied — paste it to Claude Code", symbol: "doc.on.clipboard")
    }

    func toggleEnabled() {
        settings.enabled.toggle()
    }

    func toggleEngaged() {
        // The kill switch must always work, even if camera access was revoked mid-session.
        if engaged {
            pipeline.setEngaged(false, reason: .hotkey)
            return
        }
        guard Permissions.cameraState == .granted else {
            showWelcome()
            return
        }
        if !settings.enabled { settings.enabled = true }
        pipeline.toggleEngaged(reason: .hotkey)
    }

    func selectCamera(_ id: String?) {
        settings.cameraID = id
    }

    func startCalibration() {
        guard Permissions.cameraState == .granted else {
            showWelcome()
            return
        }
        calibration?.cancel()
        if engaged { pipeline.setEngaged(false, reason: .menu) }
        let mouse = Displays.mouseLocation()
        guard let screen = Displays.screen(containingGlobal: mouse) ?? NSScreen.main,
              let displayID = Displays.stableID(of: screen) else { return }

        let controller = CalibrationController(screen: screen)
        controller.onFinish = { [weak self] outcome in
            guard let self else { return }
            self.pipeline.setFrameTap(nil)
            self.calibration = nil
            if case .calibrated(let profile) = outcome {
                self.settings.calibration.profiles[displayID] = profile
            }
            self.updateCameraMode()
        }
        calibration = controller
        pipeline.setFrameTap(Self.mainHop { [weak self] frame in
            MainActor.assumeIsolated { self?.calibration?.handle(frame) }
        })
        updateCameraMode()
        controller.begin()
    }

    func togglePreview() {
        settings.showPreview.toggle()
    }

    func toggleLaunchAtLogin() {
        do {
            try LaunchAtLogin.set(!LaunchAtLogin.isEnabled)
        } catch {
            overlay?.toast("Couldn't change Login Items: \(error.localizedDescription)", symbol: "xmark.octagon",
                           tint: Theme.warning)
        }
    }

    func toggleRecording() {
        if let url = recordingURL {
            recordingURL = nil
            pipeline.stopRecording { [weak self] count in
                self?.overlay?.toast("Saved \(count) frames", symbol: "checkmark.circle.fill")
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            return
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        startRecording(to: desktop.appendingPathComponent("Wisp-\(formatter.string(from: Date())).json"))
    }

    func showSettings() {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let launchBinding = Binding<Bool>(
            get: { LaunchAtLogin.isEnabled },
            set: { [weak self] newValue in
                do {
                    try LaunchAtLogin.set(newValue)
                } catch {
                    self?.overlay?.toast("Couldn't change Login Items", symbol: "xmark.octagon", tint: Theme.warning)
                }
            })
        let view = SettingsView(settings: settings, cameras: Camera.availableCameras(),
                                launchAtLogin: launchBinding,
                                onCalibrate: { [weak self] in self?.startCalibration() })
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Wisp Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func quit() {
        NSApp.terminate(nil)
    }
}
#endif
