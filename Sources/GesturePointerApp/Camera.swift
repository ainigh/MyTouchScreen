#if canImport(AppKit)
import AVFoundation
import CoreMedia
import Foundation

/// Capture resolutions offered in Settings. 720p is the default: Vision's hand pose accuracy
/// barely improves above it, and every extra pixel costs latency.
enum CameraResolution: String, CaseIterable, Codable {
    case vga = "640x480"
    case hd720 = "1280x720"
    case hd1080 = "1920x1080"

    var width: Int32 {
        switch self {
        case .vga: return 640
        case .hd720: return 1280
        case .hd1080: return 1920
        }
    }

    var height: Int32 {
        switch self {
        case .vga: return 480
        case .hd720: return 720
        case .hd1080: return 1080
        }
    }

    var label: String {
        switch self {
        case .vga: return "640 × 480"
        case .hd720: return "1280 × 720 (recommended)"
        case .hd1080: return "1920 × 1080"
        }
    }
}

/// A camera as shown in the picker.
struct CameraInfo: Equatable {
    let id: String
    let name: String
    let isContinuity: Bool
    let isBuiltIn: Bool
}

/// Owns the AVCaptureSession. Frames are delivered on `frameQueue` (a serial background queue)
/// via `onFrame`. Late frames are discarded by AVFoundation rather than queued, so the pipeline
/// always works on the newest image.
final class Camera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    let frameQueue = DispatchQueue(label: "app.wisp.camera.frames", qos: .userInteractive)
    private let sessionQueue = DispatchQueue(label: "app.wisp.camera.session")
    private let output = AVCaptureVideoDataOutput()
    private var currentInput: AVCaptureDeviceInput?
    private var disconnectObserver: NSObjectProtocol?
    private var connectObserver: NSObjectProtocol?
    private var runtimeErrorObserver: NSObjectProtocol?

    /// Called on `frameQueue` for every delivered frame.
    var onFrame: ((CMSampleBuffer) -> Void)?
    /// Called on the main queue with a human-readable problem.
    var onError: ((String) -> Void)?
    /// Called on the main queue after a (re)configuration with the device actually in use.
    var onConfigured: ((CameraInfo, Double) -> Void)?

    /// Only touched on `sessionQueue`.
    private var activeDeviceID: String?
    private var wantedResolution: CameraResolution = .hd720
    private var wantedDeviceID: String?
    /// Whether the app wants frames (start called, stop not). Errors only restart in this case.
    private var wantsRunning = false
    /// Consecutive runtime-error restarts; reset once the camera has stayed up for a while.
    private var restartAttempts = 0
    private var lastRuntimeError: Double = 0
    private static let maxRestartAttempts = 5

    override init() {
        super.init()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: frameQueue)
        disconnectObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil
        ) { [weak self] note in
            guard let self, let device = note.object as? AVCaptureDevice else { return }
            self.sessionQueue.async {
                guard device.uniqueID == self.activeDeviceID else { return }
                // The camera in use went away (iPhone walked off, USB unplugged): fall back.
                self.activeDeviceID = nil
                self.configureOnSessionQueue()
                if self.currentInput != nil {
                    self.reportError("\(device.localizedName) disconnected — switched cameras")
                }
            }
        }
        connectObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: nil
        ) { [weak self] note in
            guard let self, let device = note.object as? AVCaptureDevice else { return }
            self.sessionQueue.async { self.deviceConnected(device) }
        }
        runtimeErrorObserver = NotificationCenter.default.addObserver(
            forName: Self.runtimeErrorNotification, object: session, queue: nil
        ) { [weak self] note in
            guard let self else { return }
            let error = note.userInfo?.values.first { $0 is NSError } as? NSError
            self.sessionQueue.async { self.recoverFromRuntimeError(error) }
        }
    }

    /// AVCaptureSessionRuntimeErrorNotification by its string value: its Swift spelling changed
    /// between SDKs (`.AVCaptureSessionRuntimeError` vs `AVCaptureSession.runtimeErrorNotification`),
    /// and the string builds the same on every one.
    private static let runtimeErrorNotification = Notification.Name("AVCaptureSessionRuntimeErrorNotification")

    deinit {
        for observer in [disconnectObserver, connectObserver, runtimeErrorObserver] {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }

    // MARK: Devices

    static func discoverDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external],
            mediaType: .video, position: .unspecified
        ).devices
    }

    static func info(for device: AVCaptureDevice) -> CameraInfo {
        CameraInfo(id: device.uniqueID, name: device.localizedName,
                   isContinuity: device.deviceType == .continuityCamera,
                   isBuiltIn: device.deviceType == .builtInWideAngleCamera)
    }

    static func availableCameras() -> [CameraInfo] {
        discoverDevices().map(info(for:))
    }

    /// The saved choice if present; otherwise Continuity Camera (better optics, positioned at
    /// eye level), then the built-in camera, then anything.
    static func preferredDevice(savedID: String?) -> AVCaptureDevice? {
        let devices = discoverDevices()
        if let savedID, let saved = devices.first(where: { $0.uniqueID == savedID }) { return saved }
        return devices.first { $0.deviceType == .continuityCamera }
            ?? devices.first { $0.deviceType == .builtInWideAngleCamera }
            ?? devices.first
    }

    // MARK: Control

    func configure(deviceID: String?, resolution: CameraResolution) {
        sessionQueue.async {
            self.wantedDeviceID = deviceID
            self.wantedResolution = resolution
            self.restartAttempts = 0
            self.configureOnSessionQueue()
            // A new choice is also a retry after the camera gave up on runtime errors.
            if self.wantsRunning && self.currentInput != nil && !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }

    func start() {
        sessionQueue.async {
            self.wantsRunning = true
            self.restartAttempts = 0
            if self.currentInput == nil { self.configureOnSessionQueue() }
            if self.currentInput != nil && !self.session.isRunning { self.session.startRunning() }
        }
    }

    func stop() {
        sessionQueue.async {
            self.wantsRunning = false
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    // MARK: Recovery (session queue only)

    /// AVFoundation stops the session on a runtime error (device hiccup, driver reset) and never
    /// restarts it. Reopen the device and restart, backing off, and give up with a clear message
    /// if it keeps failing rather than spinning.
    private func recoverFromRuntimeError(_ error: NSError?) {
        guard wantsRunning else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // A camera that ran fine for a while since the last error gets a fresh set of retries.
        if now - lastRuntimeError > 30 { restartAttempts = 0 }
        lastRuntimeError = now
        restartAttempts += 1
        let reason = error?.localizedDescription ?? "unknown error"
        guard restartAttempts <= Self.maxRestartAttempts else {
            if session.isRunning { session.stopRunning() }
            reportError("Camera keeps failing (\(reason)) — turn Wisp off and on, or pick another camera")
            return
        }
        if restartAttempts == 1 { reportError("Camera stopped (\(reason)) — restarting") }
        let delay = 0.5 * pow(2, Double(restartAttempts - 1))
        sessionQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.wantsRunning else { return }
            // Reopen the input: after a device-level error the old one is often dead.
            self.configureOnSessionQueue()
            if self.currentInput != nil && !self.session.isRunning { self.session.startRunning() }
        }
    }

    /// A camera appeared. Switch to it if it's the user's saved choice and we're on a fallback,
    /// or if we currently have no working camera at all.
    private func deviceConnected(_ device: AVCaptureDevice) {
        let isWanted = wantedDeviceID != nil && device.uniqueID == wantedDeviceID
        guard activeDeviceID == nil || (isWanted && activeDeviceID != device.uniqueID) else { return }
        configureOnSessionQueue()
        if wantsRunning && currentInput != nil && !session.isRunning { session.startRunning() }
    }

    // MARK: Configuration (session queue only)

    private func configureOnSessionQueue() {
        guard let device = Self.preferredDevice(savedID: wantedDeviceID) else {
            // Drop the stale input so the next start() or a newly connected camera retries.
            dropCurrentInput()
            reportError("No camera found")
            return
        }
        session.beginConfiguration()
        if let currentInput {
            session.removeInput(currentInput)
            self.currentInput = nil
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                activeDeviceID = nil
                reportError("Can't use \(device.localizedName) right now")
                return
            }
            session.addInput(input)
            currentInput = input
        } catch {
            session.commitConfiguration()
            activeDeviceID = nil
            reportError("Can't open \(device.localizedName): \(error.localizedDescription)")
            return
        }
        if !session.outputs.contains(output), session.canAddOutput(output) {
            session.addOutput(output)
        }
        // GestureCore expects exactly what the camera sees (mirroring lives in calibration), so
        // pin the data output's mirroring off rather than trust each camera's default.
        if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        let fps = applyBestFormat(device, resolution: wantedResolution, desiredFPS: 60)
        session.commitConfiguration()
        activeDeviceID = device.uniqueID
        let info = Self.info(for: device)
        DispatchQueue.main.async { [weak self] in self?.onConfigured?(info, fps) }
    }

    private func dropCurrentInput() {
        activeDeviceID = nil
        guard let currentInput else { return }
        session.beginConfiguration()
        session.removeInput(currentInput)
        session.commitConfiguration()
        self.currentInput = nil
    }

    /// Pick the format matching the resolution with the highest frame rate up to `desiredFPS`.
    /// Returns the frame rate configured.
    @discardableResult
    private func applyBestFormat(_ device: AVCaptureDevice, resolution: CameraResolution, desiredFPS: Double) -> Double {
        func dims(_ format: AVCaptureDevice.Format) -> CMVideoDimensions {
            CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        }
        func maxRate(_ format: AVCaptureDevice.Format) -> Double {
            format.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 0
        }
        let exact = device.formats.filter { dims($0).width == resolution.width && dims($0).height == resolution.height }
        // If the exact size is missing, take the smallest format at least as large.
        let candidates = exact.isEmpty
            ? device.formats.filter { dims($0).width >= resolution.width }
                .sorted { dims($0).width * dims($0).height < dims($1).width * dims($1).height }
                .prefix(3).map { $0 }
            : exact
        guard let best = candidates.max(by: { min(maxRate($0), desiredFPS) < min(maxRate($1), desiredFPS) }),
              let range = best.videoSupportedFrameRateRanges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) else {
            if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
            return 30
        }
        do {
            try device.lockForConfiguration()
            device.activeFormat = best
            // Only ask for `desiredFPS` if some range of this format actually contains it: an
            // unsupported frame duration raises an Objective-C exception, which would crash.
            let desiredSupported = best.videoSupportedFrameRateRanges.contains {
                $0.minFrameRate <= desiredFPS && desiredFPS <= $0.maxFrameRate
            }
            if range.maxFrameRate <= desiredFPS || !desiredSupported {
                device.activeVideoMinFrameDuration = range.minFrameDuration
                device.unlockForConfiguration()
                return range.maxFrameRate
            }
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(desiredFPS))
            device.unlockForConfiguration()
            return desiredFPS
        } catch {
            reportError("Couldn't configure \(device.localizedName): \(error.localizedDescription)")
            return 30
        }
    }

    private func reportError(_ message: String) {
        DispatchQueue.main.async { [weak self] in self?.onError?(message) }
    }

    // MARK: AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        onFrame?(sampleBuffer)
    }
}
#endif
