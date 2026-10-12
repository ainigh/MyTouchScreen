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
    }

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
            if let h = app["hotkey"] as? [String: Any],
               let code = (h["keyCode"] as? NSNumber)?.uint32Value,
               let mods = (h["modifiers"] as? NSNumber)?.uint32Value {
                hotkey = HotkeyCombo(keyCode: code, modifiers: mods)
            }
        }
    }
}

// MARK: - Settings window

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    let cameras: [CameraInfo]
    let launchAtLogin: Binding<Bool>
    let onCalibrate: () -> Void

    var body: some View {
        TabView {
            PointerSettings(settings: settings)
                .tabItem { Label("Pointer", systemImage: "cursorarrow.motionlines") }
            GestureSettings(settings: settings)
                .tabItem { Label("Gestures", systemImage: "hand.pinch") }
            CameraSettings(settings: settings, cameras: cameras, onCalibrate: onCalibrate)
                .tabItem { Label("Camera", systemImage: "camera") }
            GeneralSettings(settings: settings, launchAtLogin: launchAtLogin)
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 520, height: 470)
    }
}

/// A labelled slider with its value shown in SF Mono.
private struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format = "%.2f"
    var help = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
            if !help.isEmpty {
                Text(help).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct PointerSettings: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Reach") {
                ValueSlider(title: "Active area", value: $settings.config.boxScale, range: 0.5...1.5,
                            format: "%.2f×",
                            help: "Smaller = less hand movement covers the screen. Larger = more precise.")
            }
            Section("Smoothing (1€ filter)") {
                ValueSlider(title: "Steadiness (min cutoff)", value: $settings.config.filter.minCutoff,
                            range: 0.1...3.0, format: "%.2f Hz",
                            help: "Lower = steadier when still, slightly slower to start moving.")
                ValueSlider(title: "Responsiveness (beta)", value: $settings.config.filter.beta,
                            range: 0...20, format: "%.1f",
                            help: "Higher = less lag on fast moves, a little more jitter.")
                ValueSlider(title: "Rest lock", value: $settings.config.restDeadZoneBox,
                            range: 0...0.012, format: "%.4f",
                            help: "How firmly a still cursor is held in place.")
            }
            Section("Precision") {
                Toggle("Slow down slow movements", isOn: $settings.config.precisionEnabled)
                ValueSlider(title: "Precision gain", value: $settings.config.precisionGain,
                            range: 0.2...1.0, format: "%.2f×")
                    .disabled(!settings.config.precisionEnabled)
            }
        }
        .formStyle(.grouped)
    }
}

private struct GestureSettings: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Pinch") {
                ValueSlider(title: "Pinch closes at", value: $settings.config.pinchEnter, range: 0.15...0.5,
                            help: "Thumb-to-finger distance (in hand sizes) that counts as a pinch. Calibration sets this per display.")
                ValueSlider(title: "Pinch opens at", value: $settings.config.pinchExit, range: 0.25...0.8)
                ValueSlider(title: "Hold to drag", value: $settings.config.dragHoldDuration,
                            range: 0.15...0.6, format: "%.2f s")
            }
            Section("Scroll") {
                ValueSlider(title: "Scroll speed", value: $settings.config.scrollSpeed, range: 0.25...4, format: "%.2f×")
                Toggle("Natural direction (content follows your fist)", isOn: $settings.config.naturalScrolling)
                Toggle("Momentum", isOn: $settings.config.momentumEnabled)
            }
            Section("More gestures") {
                Toggle("Two-hand pinch to zoom", isOn: $settings.config.zoomEnabled)
                Picker("Zoom sends", selection: $settings.zoomStyle) {
                    ForEach(ZoomStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .disabled(!settings.config.zoomEnabled)
                Toggle("Thumb + ring pinch: app switcher (⌘⇥)", isOn: $settings.config.appSwitcherEnabled)
                Toggle("Dwell to click", isOn: $settings.config.dwellClickEnabled)
                ValueSlider(title: "Dwell time", value: $settings.config.dwellClickDelay, range: 0.4...2.0, format: "%.2f s")
                    .disabled(!settings.config.dwellClickEnabled)
            }
            Section("Engage") {
                Toggle("Open palm toggles Wisp on and off", isOn: $settings.config.palmEngageEnabled)
                Text("While off, Wisp keeps the camera at a few frames per second to watch for your palm. Turn this off to stop the camera completely and use the hotkey instead.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Pointing hand", selection: $settings.config.preferredHand) {
                    Text("Automatic").tag(Chirality.unknown)
                    Text("Right").tag(Chirality.right)
                    Text("Left").tag(Chirality.left)
                }
            }
        }
        .formStyle(.grouped)
    }
}

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

private struct GeneralSettings: View {
    @ObservedObject var settings: AppSettings
    let launchAtLogin: Binding<Bool>
    @State private var recording = false
    @State private var monitor: Any?
    @State private var message = ""

    var body: some View {
        Form {
            Section("Shortcut") {
                HStack {
                    Text("Engage / disengage")
                    Spacer()
                    Button(recording ? "Press keys…" : settings.hotkey.displayString) { toggleRecording() }
                        .font(.system(size: 13, design: .monospaced))
                }
            }
            Section("Feedback") {
                Toggle("Sounds", isOn: $settings.soundsEnabled)
                Toggle("Status dot when off", isOn: $settings.showStatusGlyph)
            }
            Section("System") {
                Toggle("Launch at login", isOn: launchAtLogin)
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
