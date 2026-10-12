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
        static let showWhyNot = "showWhyNot"
        static let scrollFollowsSystem = "scrollFollowsSystem"
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
    /// Velocity mode debug readout: the last segment's numbers and the rule that fired.
    @Published var showWhyNot: Bool { didSet { defaults.set(showWhyNot, forKey: Keys.showWhyNot); changed() } }
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
        showWhyNot = defaults.object(forKey: Keys.showWhyNot) as? Bool ?? false
        scrollFollowsSystem = defaults.object(forKey: Keys.scrollFollowsSystem) as? Bool ?? true
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
        showWhyNot = false
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
            "showWhyNot": showWhyNot,
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
            if let v = app["showWhyNot"] as? Bool { showWhyNot = v }
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
                .tabItem { Label("Pointer", systemImage: "cursorarrow.motionlines") }
            GestureSettings(settings: settings)
                .tabItem { Label("Gestures", systemImage: "hand.pinch") }
            CameraSettings(settings: settings, cameras: cameras, onCalibrate: onCalibrate)
                .tabItem { Label("Camera", systemImage: "camera") }
            GeneralSettings(settings: settings, launchAtLogin: launchAtLogin,
                            onLaunchAtLoginChange: onLaunchAtLoginChange)
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 540, height: 540)
    }
}

/// A labelled slider with its value shown in SF Mono.
@MainActor
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

@MainActor
private struct PointerSettings: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Displays") {
                Toggle("Stay on the display the mouse is on when Wisp engages", isOn: $settings.config.stayOnEngagedDisplay)
                Text("Off: hold the cursor against an edge to move to the next display, and the real mouse moves Wisp to its display.")
                    .font(.caption).foregroundStyle(.secondary)
            }
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
                ValueSlider(title: "Precision slow-gain", value: $settings.config.precisionGain,
                            range: 0.2...1.0, format: "%.2f×",
                            help: "Below a slow speed the cursor moves at this fraction of your hand's speed.")
                    .disabled(!settings.config.precisionEnabled)
            }
        }
        .formStyle(.grouped)
    }
}

@MainActor
private struct GestureSettings: View {
    @ObservedObject var settings: AppSettings

    private var model: InputModel { settings.config.inputModel }
    private var isVelocity: Bool { model == .velocity }

    private var modelHelp: String {
        switch model {
        case .dwellShake:
            return "Point with your right hand. Hold still for a second and the cursor locks; it stays put for a second after you move again. In that second: wiggle (left-right-left) to click where it is locked, wiggle twice to double-click, or make a fist to press and drag; open the fist to drop. Both hands as fists: spread them apart and rest to zoom in, bring them together and rest to zoom out, move both the same way and rest to scroll. Only the last stroke before you rest counts, so close-then-widen repeats a zoom in. Both open palms turn Wisp on and off."
        case .velocity:
            return "Your hand is the mouse: a quick tap from a still hand clicks, a long flick scrolls, tap then move drags."
        case .pose:
            return "Pinch thumb and index to click, hold the pinch to drag, make a fist and move to scroll."
        }
    }

    var body: some View {
        Form {
            Section("Input model") {
                Picker("Click and scroll with", selection: $settings.config.inputModel) {
                    Text("Hold & wiggle").tag(InputModel.dwellShake)
                    Text("Velocity (flick)").tag(InputModel.velocity)
                    Text("Pose (pinch)").tag(InputModel.pose)
                }
                .pickerStyle(.segmented)
                Text(modelHelp)
                    .font(.caption).foregroundStyle(.secondary)
            }
            switch model {
            case .dwellShake:
                Section("Hold & wiggle") {
                    ValueSlider(title: "Hold still to lock the cursor", value: $settings.config.shake.lockTime,
                                range: 0.4...3.0, format: "%.1f s")
                    ValueSlider(title: "Locked after moving again", value: $settings.config.shake.wakeTime,
                                range: 0.5...2.0, format: "%.1f s",
                                help: "How long the cursor stays put once the hand moves again. Wiggle within this time to click, or make a fist to drag.")
                    ValueSlider(title: "Still means within", value: $settings.config.shake.dwellRadiusBox,
                                range: 0.003...0.03, format: "%.3f",
                                help: "Fraction of the screen width the cursor may wander while you hold still.")
                    Stepper("Click wiggle: \(settings.config.shake.reversals) changes of direction",
                            value: $settings.config.shake.reversals, in: 1...5)
                    ValueSlider(title: "Click wiggle: within", value: $settings.config.shake.window,
                                range: 0.5...2.0, format: "%.2f s")
                    ValueSlider(title: "Click wiggle: smallest stroke", value: $settings.config.shake.minStroke,
                                range: 0.1...1.0, format: "%.2f × hand",
                                help: "Shorter back-and-forth movements are ignored, so a shaky hand never clicks.")
                    ValueSlider(title: "Double click: second wiggle within", value: $settings.config.shake.doubleClickWindow,
                                range: 0.5...3.0, format: "%.1f s")
                }
                Section("Two fists: zoom and scroll") {
                    ValueSlider(title: "Smallest stroke", value: $settings.config.shake.twoHandStroke,
                                range: 0.1...1.0, format: "%.2f × hand",
                                help: "How far the fists must spread, close or move together before resting for it to zoom or scroll.")
                    ValueSlider(title: "Rest for", value: $settings.config.shake.twoHandRestTime,
                                range: 0.1...1.0, format: "%.2f s")
                    ValueSlider(title: "Zoom strength", value: $settings.config.shake.zoomGain,
                                range: 0.5...3.0, format: "%.1f×")
                    Button("Reset Hold & wiggle to defaults") { settings.config.shake = ShakeParams() }
                }
                Section("Scroll") {
                    ValueSlider(title: "Scroll speed", value: $settings.config.scrollSpeed, range: 0.25...4, format: "%.2f×")
                    ScrollDirectionToggles(settings: settings)
                }
            case .velocity:
                VelocityGestureSettings(settings: settings)
            case .pose:
                Section("Pinch") {
                    ValueSlider(title: "Pinch closes at", value: $settings.config.pinchEnter, range: 0.15...0.5,
                                help: "Thumb-to-finger distance (in hand sizes) that counts as a pinch. Calibration sets this per display.")
                    ValueSlider(title: "Pinch opens at", value: $settings.config.pinchExit, range: 0.25...0.8)
                    ValueSlider(title: "Hold to drag", value: $settings.config.dragHoldDuration,
                                range: 0.15...0.6, format: "%.2f s")
                }
                Section("Scroll") {
                    ValueSlider(title: "Scroll speed", value: $settings.config.scrollSpeed, range: 0.25...4, format: "%.2f×")
                    ScrollDirectionToggles(settings: settings)
                    Toggle("Momentum", isOn: $settings.config.momentumEnabled)
                }
            }
            if model != .dwellShake {
                Section("More gestures") {
                    Toggle(isVelocity ? "Two-hand spread to zoom" : "Two-hand pinch to zoom", isOn: $settings.config.zoomEnabled)
                    Picker("Zoom sends", selection: $settings.zoomStyle) {
                        ForEach(ZoomStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .disabled(!settings.config.zoomEnabled)
                    if model == .pose {
                        Toggle("Thumb + ring pinch: app switcher (⌘⇥)", isOn: $settings.config.appSwitcherEnabled)
                    }
                    Toggle("Dwell to click", isOn: $settings.config.dwellClickEnabled)
                    ValueSlider(title: "Dwell time", value: $settings.config.dwellClickDelay, range: 0.4...2.0, format: "%.2f s")
                        .disabled(!settings.config.dwellClickEnabled)
                }
            }
            Section("Engage") {
                Toggle("Both open palms toggle Wisp on and off", isOn: $settings.config.palmEngageEnabled)
                Text("Hold up both hands, palms open, for about half a second. While off, Wisp keeps the camera at a few frames per second to watch for your palms. Turn this off to stop the camera completely and use the hotkey instead.")
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

/// Natural direction, or follow whatever System Settings says.
@MainActor
private struct ScrollDirectionToggles: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Toggle("Follow the system scroll direction", isOn: $settings.scrollFollowsSystem)
        Toggle("Natural direction (content follows your hand)", isOn: Binding(
            get: { settings.scrollFollowsSystem ? AppSettings.systemNaturalScrolling : settings.config.naturalScrolling },
            set: { settings.config.naturalScrolling = $0 }))
            .disabled(settings.scrollFollowsSystem)
    }
}

/// Velocity mode: taps, scroll flicks, and every `VelocityParams` field under "Advanced".
@MainActor
private struct VelocityGestureSettings: View {
    @ObservedObject var settings: AppSettings
    @State private var showsAdvanced = false

    private struct Param {
        let title: String
        let key: WritableKeyPath<VelocityParams, Double>
        let range: ClosedRange<Double>
        let format: String
    }

    /// Velocities are hand-space units per second; distances are hand sizes (× hs).
    private static var params: [Param] {
        [
            Param(title: "Fast above (vEnter)", key: \.vEnter, range: 0.3...2.5, format: "%.2f /s"),
            Param(title: "Slow below (vExit)", key: \.vExit, range: 0.1...1.5, format: "%.2f /s"),
            Param(title: "Longest segment", key: \.maxSegment, range: 0.2...1.0, format: "%.2f s"),
            Param(title: "Tap: longest", key: \.clickMaxDuration, range: 0.08...0.4, format: "%.2f s"),
            Param(title: "Tap: largest displacement", key: \.clickMaxDisp, range: 0.3...2.0, format: "%.2f × hs"),
            Param(title: "Tap: longest path", key: \.clickMaxPath, range: 0.5...3.0, format: "%.2f × hs"),
            Param(title: "Still before a tap: below", key: \.preClickStillV, range: 0.05...0.8, format: "%.2f /s"),
            Param(title: "Still before a tap: for", key: \.preClickStillTime, range: 0...0.3, format: "%.2f s"),
            Param(title: "Scroll: shortest flick", key: \.scrollMinDisp, range: 0.8...4.0, format: "%.2f × hs"),
            Param(title: "Scroll: peak speed without return", key: \.scrollMinPeak, range: 0.8...4.0, format: "%.2f /s"),
            Param(title: "Counts as returned at", key: \.returnFraction, range: 0.1...0.9, format: "%.2f"),
            Param(title: "Axis ratio", key: \.axisRatio, range: 1.0...4.0, format: "%.2f"),
            Param(title: "Double click: within", key: \.doubleClickWindow, range: 0.1...0.8, format: "%.2f s"),
            Param(title: "Double click: distance", key: \.doubleClickDisp, range: 0.1...2.0, format: "%.2f × hs"),
            Param(title: "Drag: start within", key: \.dragStartWindow, range: 0.1...1.0, format: "%.2f s"),
            Param(title: "Drag: moving above", key: \.dragMoveMin, range: 0.05...1.0, format: "%.2f /s"),
            Param(title: "Drag: moving for", key: \.dragConfirmTime, range: 0.03...0.4, format: "%.2f s"),
            Param(title: "Drop: still below", key: \.dragStillV, range: 0.02...0.5, format: "%.2f /s"),
            Param(title: "Drop: still for", key: \.dragStillTime, range: 0.1...1.5, format: "%.2f s"),
            Param(title: "Two hands together within", key: \.twoHandWindow, range: 0.05...0.5, format: "%.2f s"),
            Param(title: "Coherence angle", key: \.coherenceAngle, range: 10...120, format: "%.0f°"),
            Param(title: "Glitch jump", key: \.glitchDisp, range: 1.0...6.0, format: "%.1f × hs"),
            Param(title: "Refractory", key: \.refractory, range: 0...0.5, format: "%.2f s"),
            Param(title: "Minimum confidence", key: \.minConfidence, range: 0...1, format: "%.2f"),
        ]
    }

    private func binding(_ key: WritableKeyPath<VelocityParams, Double>) -> Binding<Double> {
        Binding(get: { settings.config.velocity[keyPath: key] },
                set: { settings.config.velocity[keyPath: key] = $0 })
    }

    var body: some View {
        Section("Taps") {
            Picker("Left click is a tap", selection: $settings.config.velocity.clickAxis) {
                Text("Up or down").tag(ClickAxis.vertical)
                Text("Sideways").tag(ClickAxis.horizontal)
                Text("Any direction").tag(ClickAxis.any)
            }
            Toggle("Cross-direction tap right-clicks", isOn: $settings.config.velocity.rightClickEnabled)
                .disabled(settings.config.velocity.clickAxis == .any)
            Toggle("Tap, then move to drag", isOn: $settings.config.velocity.dragEnabled)
        }
        Section("Scroll") {
            ValueSlider(title: "Scroll gain", value: $settings.config.velocity.scrollGain, range: 300...2500,
                        format: "%.0f", help: "Points per second of scroll for each unit of flick speed.")
            ValueSlider(title: "Momentum", value: $settings.config.velocity.momentumDecay, range: 0.85...0.98,
                        format: "%.3f", help: "Speed kept per 1/60 s while gliding. Higher glides further.")
            ScrollDirectionToggles(settings: settings)
        }
        Section("Feedback") {
            Toggle("Show “why not?” readout", isOn: $settings.showWhyNot)
            Text("Shows the last flick's duration, distance, path, peak speed, axis and the rule that decided. Use it to report a gesture that didn't do what you expected.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section {
            DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
                Stepper("Frames above vEnter to start: \(settings.config.velocity.framesEnter)",
                        value: $settings.config.velocity.framesEnter, in: 1...6)
                Stepper("Frames below vExit to end: \(settings.config.velocity.framesExit)",
                        value: $settings.config.velocity.framesExit, in: 1...8)
                Text("Frames are counted at 60 fps; a 30 fps camera needs half as many.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(Self.params.indices, id: \.self) { index in
                    let param = Self.params[index]
                    ValueSlider(title: param.title, value: binding(param.key), range: param.range, format: param.format)
                }
                Button("Reset to tuned defaults") {
                    var fresh = VelocityParams()
                    // The switches above are preferences, not tuning.
                    fresh.clickAxis = settings.config.velocity.clickAxis
                    fresh.rightClickEnabled = settings.config.velocity.rightClickEnabled
                    fresh.dragEnabled = settings.config.velocity.dragEnabled
                    settings.config.velocity = fresh
                }
            }
        }
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
