#if canImport(AppKit)
import AppKit
import Foundation
import GestureCore
import SwiftUI
import UniformTypeIdentifiers

/// Everything the user can change, persisted in UserDefaults. Gesture tunables live in
/// `config` (GestureCore's `GestureConfig`); the rest are app-level preferences.
@MainActor
final class AppSettings: ObservableObject {
    enum Keys {
        static let config = "gestureConfig"
        static let cameraID = "cameraID"
        static let resolution = "cameraResolution"
        static let showSkeleton = "showSkeleton"
        static let showPreview = "showPreview"
        static let sounds = "soundsEnabled"
        static let statusGlyph = "showStatusGlyph"
        static let zoomStyle = "zoomStyle"
        static let hotkey = "hotkey"
        static let calibration = "calibration"
        static let onboarded = "hasCompletedOnboarding"
        static let enabled = "enabled"
        static let previewCorner = "previewCorner"
        static let scrollFollowsSystem = "scrollFollowsSystem"
        static let pointerTuning = "pointerTuningVersion"
    }

    /// Bumped when the pointer's smoothing changes meaning. Saved smoothing from an older version
    /// is reset to the new defaults once: v2 is the laser-pointer model, where the old sliders'
    /// values (often moved while hunting for a fix) would make it laggy or jittery.
    static let pointerTuningVersion = 2

    private let defaults: UserDefaults
    /// Called after any change has been saved.
    var onChange: (() -> Void)?

    @Published var config: GestureConfig { didSet { saveJSON(config, Keys.config) } }
    @Published var cameraID: String? { didSet { defaults.set(cameraID, forKey: Keys.cameraID); changed() } }
    @Published var resolution: CameraResolution { didSet { defaults.set(resolution.rawValue, forKey: Keys.resolution); changed() } }
    @Published var showSkeleton: Bool { didSet { defaults.set(showSkeleton, forKey: Keys.showSkeleton); changed() } }
    @Published var showPreview: Bool { didSet { defaults.set(showPreview, forKey: Keys.showPreview); changed() } }
    @Published var soundsEnabled: Bool { didSet { defaults.set(soundsEnabled, forKey: Keys.sounds); changed() } }
    @Published var showStatusGlyph: Bool { didSet { defaults.set(showStatusGlyph, forKey: Keys.statusGlyph); changed() } }
    @Published var zoomStyle: ZoomStyle { didSet { defaults.set(zoomStyle.rawValue, forKey: Keys.zoomStyle); changed() } }
    @Published var hotkey: HotkeyCombo { didSet { saveJSON(hotkey, Keys.hotkey) } }
    @Published var calibration: CalibrationSet { didSet { saveJSON(calibration, Keys.calibration) } }
    @Published var hasCompletedOnboarding: Bool { didSet { defaults.set(hasCompletedOnboarding, forKey: Keys.onboarded); changed() } }
    /// Master switch. Off = camera off; only the hotkey or the menu turns Wisp back on.
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: Keys.enabled); changed() } }
    /// 0 top-left, 1 top-right, 2 bottom-right, 3 bottom-left.
    @Published var previewCorner: Int { didSet { defaults.set(previewCorner, forKey: Keys.previewCorner); changed() } }
    /// Scroll direction follows System Settings → Trackpad/Mouse → Natural scrolling.
    @Published var scrollFollowsSystem: Bool { didSet { defaults.set(scrollFollowsSystem, forKey: Keys.scrollFollowsSystem); changed() } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        config = Self.loadConfig(defaults) ?? GestureConfig()
        cameraID = defaults.string(forKey: Keys.cameraID)
        resolution = CameraResolution(rawValue: defaults.string(forKey: Keys.resolution) ?? "") ?? .hd720
        showSkeleton = defaults.object(forKey: Keys.showSkeleton) as? Bool ?? true
        showPreview = defaults.object(forKey: Keys.showPreview) as? Bool ?? false
        soundsEnabled = defaults.object(forKey: Keys.sounds) as? Bool ?? true
        showStatusGlyph = defaults.object(forKey: Keys.statusGlyph) as? Bool ?? true
        zoomStyle = ZoomStyle(rawValue: defaults.string(forKey: Keys.zoomStyle) ?? "") ?? .keyboard
        hotkey = Self.loadJSON(HotkeyCombo.self, defaults, Keys.hotkey) ?? .default
        calibration = Self.loadJSON(CalibrationSet.self, defaults, Keys.calibration) ?? CalibrationSet()
        hasCompletedOnboarding = defaults.bool(forKey: Keys.onboarded)
        enabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        previewCorner = defaults.object(forKey: Keys.previewCorner) as? Int ?? 3
        scrollFollowsSystem = defaults.object(forKey: Keys.scrollFollowsSystem) as? Bool ?? true
        if defaults.integer(forKey: Keys.pointerTuning) < Self.pointerTuningVersion {
            // Property observers don't run in init, so save explicitly.
            config.resetPointerTuning()
            saveJSON(config, Keys.config)
            defaults.set(Self.pointerTuningVersion, forKey: Keys.pointerTuning)
        }
    }

    /// The system's natural-scrolling choice (the global `com.apple.swipescrolldirection`
    /// default; absent means the macOS default, natural).
    static var systemNaturalScrolling: Bool {
        UserDefaults.standard.object(forKey: "com.apple.swipescrolldirection") as? Bool ?? true
    }

    /// The config the pipeline runs: the saved one, with the scroll direction taken from the
    /// system when that's what the user chose.
    var effectiveConfig: GestureConfig {
        var c = config
        if scrollFollowsSystem { c.naturalScrolling = Self.systemNaturalScrolling }
        return c
    }

    private func changed() { onChange?() }

    private func saveJSON<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
        changed()
    }

    private static func loadJSON<T: Decodable>(_ type: T.Type, _ defaults: UserDefaults, _ key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func loadConfig(_ defaults: UserDefaults) -> GestureConfig? {
        guard let data = defaults.data(forKey: Keys.config) else { return nil }
        return try? GestureConfig.decodeLenient(data)
    }

    /// Restore every gesture and app preference to its default. Calibration and the
    /// onboarding flag are kept: they describe the user's setup, not a preference.
    func resetToDefaults() {
        config = GestureConfig()
        resolution = .hd720
        showSkeleton = true
        showPreview = false
        soundsEnabled = true
        showStatusGlyph = true
        zoomStyle = .keyboard
        hotkey = .default
        scrollFollowsSystem = true
    }

    // MARK: Export / import

    func exportJSON() throws -> Data {
        let app: [String: Any] = [
            "resolution": resolution.rawValue,
            "showSkeleton": showSkeleton,
            "showPreview": showPreview,
            "soundsEnabled": soundsEnabled,
            "showStatusGlyph": showStatusGlyph,
            "zoomStyle": zoomStyle.rawValue,
            "scrollFollowsSystem": scrollFollowsSystem,
            "hotkey": ["keyCode": hotkey.keyCode, "modifiers": hotkey.modifiers],
        ]
        let root: [String: Any] = [
            "format": "wisp-settings",
            "version": 1,
            "config": try JSONSerialization.jsonObject(with: JSONEncoder().encode(config)),
            "calibration": try JSONSerialization.jsonObject(with: JSONEncoder().encode(calibration)),
            "app": app,
        ]
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    func importJSON(_ data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["format"] as? String == "wisp-settings" else {
            throw CocoaError(.fileReadCorruptFile)
        }
        if let configObject = root["config"] {
            config = try GestureConfig.decodeLenient(JSONSerialization.data(withJSONObject: configObject))
        }
        if let calibrationObject = root["calibration"],
           let set = try? JSONDecoder().decode(CalibrationSet.self, from: JSONSerialization.data(withJSONObject: calibrationObject)) {
            calibration = set
        }
        if let app = root["app"] as? [String: Any] {
            if let v = app["resolution"] as? String, let r = CameraResolution(rawValue: v) { resolution = r }
            if let v = app["showSkeleton"] as? Bool { showSkeleton = v }
            if let v = app["showPreview"] as? Bool { showPreview = v }
            if let v = app["soundsEnabled"] as? Bool { soundsEnabled = v }
            if let v = app["showStatusGlyph"] as? Bool { showStatusGlyph = v }
            if let v = app["zoomStyle"] as? String, let z = ZoomStyle(rawValue: v) { zoomStyle = z }
            if let v = app["scrollFollowsSystem"] as? Bool { scrollFollowsSystem = v }
            if let h = app["hotkey"] as? [String: Any],
               let code = (h["keyCode"] as? NSNumber)?.uint32Value,
               let mods = (h["modifiers"] as? NSNumber)?.uint32Value {
                hotkey = HotkeyCombo(keyCode: code, modifiers: mods)
            }
        }
    }
}

// MARK: - Settings window

@MainActor
struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    let cameras: [CameraInfo]
    @ObservedObject var launchAtLogin: LaunchAtLoginModel
    let onLaunchAtLoginChange: (Bool) -> Void
    let onCalibrate: () -> Void

    var body: some View {
        TabView {
            PointerSettings(settings: settings)
                .tabItem { Label("Pointer", systemImage: "cursorarrow.rays") }
            CameraSettings(settings: settings, cameras: cameras, onCalibrate: onCalibrate)
                .tabItem { Label("Camera", systemImage: "camera") }
            GeneralSettings(settings: settings, launchAtLogin: launchAtLogin,
                            onLaunchAtLoginChange: onLaunchAtLoginChange)
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 520, height: 500)
    }
}

/// A slider described by what its two ends do, not by a number.
@MainActor
private struct EndsSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let low: String
    let high: String
    var help = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            Slider(value: $value, in: range) {
                EmptyView()
            } minimumValueLabel: {
                Text(low).font(.caption).foregroundStyle(.secondary)
            } maximumValueLabel: {
                Text(high).font(.caption).foregroundStyle(.secondary)
            }
            if !help.isEmpty {
                Text(help).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

@MainActor
private struct PointerSettings: View {
    @ObservedObject var settings: AppSettings

    private let howItWorks = "Wisp is an invisible laser pointer: the cursor goes wherever your index finger points, at any speed, and holds still while your hand does. Wiggle your finger (left-right-left) to click there; wiggle twice for a double click. Make a fist and hold it a moment to grab and drag; open your hand to drop. Both open palms turn Wisp on and off."

    var body: some View {
        Form {
            Section("How it works") {
                Text(howItWorks).font(.caption).foregroundStyle(.secondary)
            }
            Section("Feel") {
                EndsSlider(title: "Steadiness", value: $settings.config.steadiness, range: 0...1,
                           low: "Snappy", high: "Steady",
                           help: "Toward Steady if the cursor shivers while your hand is still; toward Snappy if it trails behind your finger.")
                Picker("Cursor speed", selection: $settings.config.pointerResponse) {
                    ForEach(PointerResponse.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text(settings.config.pointerResponse.summary)
                    .font(.caption).foregroundStyle(.secondary)
                EndsSlider(title: "Hand movement to cover the screen", value: $settings.config.boxScale,
                           range: 0.5...1.5, low: "Less", high: "More",
                           help: "Less: small movements cross the whole screen. More: bigger movements, finer aim. Calibrating (Camera tab) sets the area by pointing at the corners.")
                Picker("Pointing hand", selection: $settings.config.preferredHand) {
                    Text("Automatic (right)").tag(Chirality.unknown)
                    Text("Right").tag(Chirality.right)
                    Text("Left").tag(Chirality.left)
                }
                Button("Reset to Defaults") {
                    settings.config.resetPointerTuning()
                    settings.config.boxScale = GestureConfig().boxScale
                }
            }
            if NSScreen.screens.count > 1 {
                Section("Displays") {
                    Toggle("Stay on the display the mouse is on when Wisp turns on", isOn: $settings.config.stayOnEngagedDisplay)
                    Text("Off: hold the cursor against an edge to move to the next display.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

@MainActor
private struct CameraSettings: View {
    @ObservedObject var settings: AppSettings
    let cameras: [CameraInfo]
    let onCalibrate: () -> Void

    var body: some View {
        Form {
            Section("Camera") {
                Picker("Device", selection: Binding(
                    get: { settings.cameraID ?? "" },
                    set: { settings.cameraID = $0.isEmpty ? nil : $0 })) {
                    Text("Automatic (prefer iPhone)").tag("")
                    ForEach(cameras, id: \.id) { Text($0.name).tag($0.id) }
                }
                Picker("Resolution", selection: $settings.resolution) {
                    ForEach(CameraResolution.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            }
            Section("Preview") {
                Toggle("Show camera preview", isOn: $settings.showPreview)
                Toggle("Draw hand skeleton", isOn: $settings.showSkeleton)
            }
            Section("Calibration") {
                HStack {
                    Text(settings.calibration.profiles.isEmpty ? "Using the default active area" :
                            "Calibrated displays: \(settings.calibration.profiles.count)")
                    Spacer()
                    Button("Calibrate…", action: onCalibrate)
                }
                Button("Forget Calibration") { settings.calibration = CalibrationSet() }
                    .disabled(settings.calibration.profiles.isEmpty)
            }
        }
        .formStyle(.grouped)
    }
}

@MainActor
private struct GeneralSettings: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var launchAtLogin: LaunchAtLoginModel
    let onLaunchAtLoginChange: (Bool) -> Void
    @State private var recording = false
    @State private var monitor: Any?
    @State private var message = ""

    var body: some View {
        Form {
            Section("Turning Wisp on and off") {
                HStack {
                    Text("Shortcut")
                    Spacer()
                    Button(recording ? "Press keys…" : settings.hotkey.displayString) { toggleRecording() }
                        .font(.system(size: 13, design: .monospaced))
                }
                Toggle("Both open palms turn Wisp on and off", isOn: $settings.config.palmEngageEnabled)
                Text("Wisp stays on until you turn it off, even while your hand is out of view. With the palms off the camera stops completely while Wisp is off.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Feedback") {
                Toggle("Sounds", isOn: $settings.soundsEnabled)
                Toggle("Status dot when off", isOn: $settings.showStatusGlyph)
            }
            Section("System") {
                // Reads the model, writes through the controller: after any attempt the model
                // re-reads the system, so a failed change snaps the toggle back.
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { onLaunchAtLoginChange($0) }))
                    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                        // The user may have changed it in System Settings meanwhile.
                        launchAtLogin.refresh()
                    }
            }
            Section("Settings file") {
                HStack {
                    Button("Export…") { exportSettings() }
                    Button("Import…") { importSettings() }
                    Spacer()
                    Button("Reset to Defaults") { settings.resetToDefaults() }
                }
                if !message.isEmpty {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onDisappear { stopRecording() }
    }

    private func toggleRecording() {
        if recording { stopRecording(); return }
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Esc cancels
                stopRecording()
                return nil
            }
            if let combo = HotkeyCombo(event: event) {
                settings.hotkey = combo
                stopRecording()
                return nil
            }
            message = "Use at least one of ⌃ ⌥ ⌘ in the shortcut."
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }

    private func exportSettings() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Wisp Settings.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try settings.exportJSON().write(to: url, options: .atomic)
            message = "Exported to \(url.lastPathComponent)"
        } catch {
            message = "Export failed: \(error.localizedDescription)"
        }
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try settings.importJSON(Data(contentsOf: url))
            message = "Imported \(url.lastPathComponent)"
        } catch {
            message = "That file isn't a Wisp settings export."
        }
    }
}
#endif
