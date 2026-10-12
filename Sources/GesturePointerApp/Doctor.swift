#if canImport(AppKit)
import AppKit
import AVFoundation
import Foundation
import GestureCore
import QuartzCore

/// `--doctor`: a plain-text health report the owner can paste back verbatim.
/// Prints permissions, cameras, displays, then measures camera fps and Vision latency for 5 s.
final class Doctor {
    private var problems: [String] = []

    func run() -> Int32 {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        print("Wisp doctor — GesturePointer \(version)")
        print("macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion), \(Self.architecture())")
        print("Bundle: \(Bundle.main.bundlePath)")
        if !Bundle.main.bundlePath.hasSuffix(".app") {
            note("Running outside GesturePointer.app: macOS grants permissions to the terminal, not to Wisp. Use `make doctor`.")
        }

        print("\nPermissions")
        let camera = Permissions.cameraState
        print("  Camera:        \(camera.label)")
        if camera != .granted { note("Camera access is \(camera.label). Run the app once and allow it, or enable it in System Settings → Privacy & Security → Camera.") }
        let ax = Permissions.accessibilityGranted
        print("  Accessibility: \(ax ? "granted" : "not granted")")
        if !ax { note("Accessibility is not granted, so Wisp can't move the cursor or click. Enable GesturePointer in System Settings → Privacy & Security → Accessibility.") }

        print("\nCameras")
        let devices = Camera.discoverDevices()
        let preferred = Camera.preferredDevice(savedID: UserDefaults.standard.string(forKey: AppSettings.Keys.cameraID))
        if devices.isEmpty { note("No camera found.") }
        for device in devices {
            let marker = device.uniqueID == preferred?.uniqueID ? "*" : " "
            let kind: String
            switch device.deviceType {
            case .continuityCamera: kind = "continuity"
            case .builtInWideAngleCamera: kind = "built-in"
            default: kind = "external"
            }
            print("  \(marker) \(device.localizedName)  [\(kind)]  \(Self.bestMode(device))")
        }

        print("\nDisplays")
        for screen in NSScreen.screens {
            guard let id = Displays.displayID(of: screen) else { continue }
            let bounds = CGDisplayBounds(id)
            let main = id == CGMainDisplayID() ? "*" : " "
            print(String(format: "  %@ %@  %.0fx%.0f pt @%.0fx  origin (%.0f, %.0f)",
                         main, screen.localizedName, bounds.width, bounds.height,
                         screen.backingScaleFactor, bounds.origin.x, bounds.origin.y))
        }

        if camera == .granted, let device = preferred {
            measure(device: device)
        } else {
            print("\nSkipping the 5 s camera measurement (no camera access or no camera).")
        }

        print("")
        if problems.isEmpty {
            print("Result: everything looks good.")
            return 0
        }
        print("Result: \(problems.count) problem(s):")
        for (i, problem) in problems.enumerated() { print("  \(i + 1). \(problem)") }
        return 1
    }

    private func note(_ problem: String) {
        problems.append(problem)
    }

    private func measure(device: AVCaptureDevice) {
        print("\nMeasuring \(device.localizedName) for 5 s… (hold a hand up to test tracking)")
        let camera = Camera()
        let tracker = HandTracker()
        let lock = NSLock()
        var frames = 0, framesWithHands = 0, visionTotal = 0.0
        var configuredFPS = 0.0
        camera.onConfigured = { _, fps in configuredFPS = fps }
        camera.onError = { message in print("  camera error: \(message)") }
        camera.onFrame = { buffer in
            let start = CACurrentMediaTime()
            guard let frame = tracker.process(buffer, timestamp: start) else { return }
            let elapsed = CACurrentMediaTime() - start
            lock.lock()
            frames += 1
            visionTotal += elapsed
            if !frame.hands.isEmpty { framesWithHands += 1 }
            lock.unlock()
        }
        camera.configure(deviceID: device.uniqueID, resolution: .hd720)
        camera.start()
        // Let the camera warm up (auto exposure) before counting.
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        lock.lock(); frames = 0; framesWithHands = 0; visionTotal = 0; lock.unlock()
        RunLoop.main.run(until: Date().addingTimeInterval(5.0))
        camera.stop()
        lock.lock()
        let fps = Double(frames) / 5.0
        let visionMs = frames > 0 ? visionTotal / Double(frames) * 1000 : 0
        let handFrames = framesWithHands
        let total = frames
        lock.unlock()
        print(String(format: "  configured %.0f fps, measured %.1f fps, Vision %.1f ms/frame, hand seen in %d/%d frames",
                     configuredFPS, fps, visionMs, handFrames, total))
        if fps < 20 { note(String(format: "Camera delivered only %.1f fps; expect sluggish tracking. Try better lighting or another camera.", fps)) }
        if visionMs > 25 { note(String(format: "Vision takes %.1f ms per frame; the Mac may be under load.", visionMs)) }
    }

    private static func bestMode(_ device: AVCaptureDevice) -> String {
        var best: (w: Int32, h: Int32, fps: Double) = (0, 0, 0)
        for format in device.formats {
            let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let fps = format.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 0
            if d.width == 1280 && d.height == 720 && fps > best.fps { best = (d.width, d.height, fps) }
        }
        if best.fps == 0 { return "no 1280x720 mode (will use the closest)" }
        return String(format: "1280x720 up to %.0f fps", best.fps)
    }

    private static func architecture() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
#endif
