#if canImport(AppKit)
import AppKit
import ApplicationServices
import AVFoundation
import SwiftUI

enum PermissionState: Equatable {
    case granted, denied, notDetermined

    var label: String {
        switch self {
        case .granted: return "granted"
        case .denied: return "denied"
        case .notDetermined: return "not asked yet"
        }
    }
}

/// Camera and Accessibility status and prompts. Wisp needs both: the camera to see the hand,
/// Accessibility to post mouse and keyboard events (and for the global hotkey to be reliable).
enum Permissions {
    static var cameraState: PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    /// Completion runs on the main queue.
    static func requestCamera(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    /// Set once Accessibility has worked for any build of Wisp on this Mac.
    private static let grantedBeforeKey = "accessibilityGrantedBefore"

    static func noteAccessibilityGranted() {
        UserDefaults.standard.set(true, forKey: grantedBeforeKey)
    }

    /// After an update, macOS can keep Wisp's Accessibility switch on while no longer trusting the
    /// new build (the grant was tied to the old build's signature). Toggling the switch doesn't
    /// fix that; only removing the entry does. So when an earlier build was trusted and this one
    /// isn't, remove our own stale entry and ask again: the user just turns the switch on. Runs
    /// once per lapse, so someone who switched Wisp off on purpose isn't nagged on every launch.
    static func repairAccessibilityAfterUpdate() {
        let defaults = UserDefaults.standard
        guard !AXIsProcessTrusted(), defaults.bool(forKey: grantedBeforeKey) else { return }
        defaults.set(false, forKey: grantedBeforeKey)
        resetAccessibilityEntry()
        promptAccessibility()
    }

    /// Removes this app's entry from the Accessibility list (`tccutil reset`, which only touches
    /// our own bundle identifier and needs no admin rights). Only called while untrusted, so
    /// nothing that works is lost.
    static func resetAccessibilityEntry() {
        guard !AXIsProcessTrusted(), let bundleID = Bundle.main.bundleIdentifier else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", "Accessibility", bundleID]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            NSLog("Wisp: tccutil reset failed: \(error.localizedDescription)")
        }
    }

    /// Shows the system "would like to control this computer" prompt, which also adds the app
    /// to the Accessibility list so the user only has to flip the switch.
    static func promptAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openCameraSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    private static func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}

/// Polls permission status once a second while the welcome window is open, because macOS does
/// not notify apps when the user flips the Accessibility switch.
@MainActor
final class PermissionMonitor: ObservableObject {
    @Published private(set) var camera: PermissionState = Permissions.cameraState
    @Published private(set) var accessibility: Bool = Permissions.accessibilityGranted
    private var timer: Timer?

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let newCamera = Permissions.cameraState
        let newAX = Permissions.accessibilityGranted
        if newCamera != camera { camera = newCamera }
        if newAX != accessibility { accessibility = newAX }
    }
}

// MARK: - Welcome window

/// First-run walkthrough: Camera → Accessibility → camera choice → calibrate (or skip).
@MainActor
struct WelcomeView: View {
    @ObservedObject var monitor: PermissionMonitor
    @ObservedObject var settings: AppSettings
    let cameras: [CameraInfo]
    let onCalibrate: () -> Void
    let onFinish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "hand.point.up.left.fill")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(Color(nsColor: Theme.accent))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to Wisp")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                    Text("Point at the screen. Wiggle your finger to click, make a fist to drag. Fast movement never moves the cursor.")
                        .foregroundStyle(.secondary)
                }
            }

            step(number: 1, title: "Camera",
                 detail: "Wisp watches your hand. Video stays on this Mac and is never recorded.",
                 done: monitor.camera == .granted) {
                if monitor.camera == .notDetermined {
                    Button("Allow Camera") { Permissions.requestCamera { _ in monitor.refresh() } }
                } else if monitor.camera == .denied {
                    Button("Open Camera Settings") { Permissions.openCameraSettings() }
                }
            }

            step(number: 2, title: "Accessibility",
                 detail: "Lets Wisp move the pointer and click. Turn on “GesturePointer” in the list — the app itself, not Terminal. If it already looks on, press the button again: Wisp clears its old entry first, so the switch you turn on is the right one.",
                 done: monitor.accessibility) {
                Button("Open Accessibility Settings") {
                    // A stale entry from an earlier build would look on but not work.
                    Permissions.resetAccessibilityEntry()
                    Permissions.promptAccessibility()
                    Permissions.openAccessibilitySettings()
                }
            }

            step(number: 3, title: "Camera choice",
                 detail: "An iPhone (Continuity Camera) at eye level tracks best; the built-in camera works fine.",
                 done: true) {
                Picker("", selection: Binding(
                    get: { settings.cameraID ?? cameras.first?.id ?? "" },
                    set: { settings.cameraID = $0.isEmpty ? nil : $0 })) {
                    ForEach(cameras, id: \.id) { camera in
                        Text(camera.name + (camera.isContinuity ? "  (iPhone)" : "")).tag(camera.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 260)
            }

            step(number: 4, title: "Calibrate (20 s, optional)",
                 detail: "Point at each corner of the screen. Skipping uses sensible defaults.",
                 done: false) {
                EmptyView()
            }

            HStack {
                Text("Engage: hold up both open palms, or press \(settings.hotkey.displayString)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Skip Calibration") { onFinish() }
                    .disabled(monitor.camera != .granted)
                Button("Calibrate") { onCalibrate() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(monitor.camera != .granted)
            }
        }
        .padding(24)
        .frame(width: 540)
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
    }

    private func step<Accessory: View>(number: Int, title: String, detail: String, done: Bool,
                                        @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(done ? Color(nsColor: Theme.accent) : Color.secondary.opacity(0.2))
                    .frame(width: 26, height: 26)
                if done {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                } else {
                    Text("\(number)").font(.system(size: 13, weight: .semibold, design: .rounded))
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14, weight: .semibold, design: .rounded))
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                accessory()
            }
            Spacer(minLength: 0)
        }
    }
}
#endif
