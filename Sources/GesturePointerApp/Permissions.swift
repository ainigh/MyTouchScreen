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
                    Text("Point at the screen. Hold still to click. Wiggle to scroll.")
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
                 detail: "Lets Wisp move the pointer and click. Turn on “GesturePointer” in the list — the app itself, not Terminal. After an update, if it's already on but Wisp still asks, remove it with − and turn it on again.",
                 done: monitor.accessibility) {
                Button("Open Accessibility Settings") {
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
                 detail: "Point at each corner of the screen, then pinch three times. Skipping uses sensible defaults.",
                 done: false) {
                EmptyView()
            }

            HStack {
                Text("Engage: hold up an open palm, or press \(settings.hotkey.displayString)")
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
