import AVFoundation
import CoreMediaIO
import Combine
import SwiftUI

/// Discovers a USB-connected iPhone exposed as a screen-capture device (the same
/// mechanism QuickTime's "Movie Recording" uses) and runs a low-latency capture session.
@MainActor
final class CaptureController: NSObject, ObservableObject {
    enum Status {
        case waitingForDevice
        case accessDenied
        case streaming
        case error(String)
    }

    @Published private(set) var status: Status = .waitingForDevice
    @Published private(set) var deviceName: String?
    /// Pixel dimensions of the incoming stream (portrait or landscape).
    @Published private(set) var streamSize: CGSize?
    /// Hardware identifier like "iPhone18,2", read from the phone's sibling
    /// Continuity Camera device (the screen device only reports "iOS Device").
    @Published private(set) var modelIdentifier: String?

    let session = AVCaptureSession()
    let media = MediaExporter()

    private var device: AVCaptureDevice?
    private var formatObservation: NSKeyValueObservation?
    private var discovery: AVCaptureDevice.DiscoverySession?
    private var discoveryObservation: NSKeyValueObservation?
    private var pollTimer: Timer?
    private let sessionQueue = DispatchQueue(label: "de.consti.present.capture")
    private let frameQueue = DispatchQueue(label: "de.consti.present.frames")
    private let videoOutput = AVCaptureVideoDataOutput()

    private let latestFrameLock = NSLock()
    nonisolated(unsafe) private var _latestFrame: CVPixelBuffer?
    nonisolated var latestFrame: CVPixelBuffer? {
        latestFrameLock.lock()
        defer { latestFrameLock.unlock() }
        return _latestFrame
    }

    /// Whether the stream itself currently renders the Dynamic Island (it
    /// only does while the island is active — idle mirrors omit it, so the
    /// app fills in a black pill). Sampled from incoming frames.
    @Published private(set) var streamShowsIsland = false
    nonisolated(unsafe) private var _islandInStream = false
    nonisolated(unsafe) private var frameCounter = 0
    nonisolated(unsafe) private var pendingIslandResult: (value: Bool, streak: Int) = (false, 0)
    nonisolated var islandOverlayNeededNow: Bool {
        latestFrameLock.lock()
        defer { latestFrameLock.unlock() }
        return !_islandInStream
    }

    var isStreaming: Bool {
        if case .streaming = status { return true }
        return false
    }

    override init() {
        super.init()
        Log.write("--- launch")
        Self.allowScreenCaptureDevices()

        NotificationCenter.default.addObserver(
            self, selector: #selector(deviceWasDisconnected(_:)),
            name: AVCaptureDevice.wasDisconnectedNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(sessionRuntimeError(_:)),
            name: AVCaptureSession.runtimeErrorNotification, object: session)
        // iPhone screen devices report activeFormat as 0x0; the real stream
        // dimensions (and rotation changes) arrive via the input port.
        NotificationCenter.default.addObserver(
            self, selector: #selector(portFormatChanged(_:)),
            name: .AVCaptureInputPortFormatDescriptionDidChange, object: nil)

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            Log.write("camera access already authorized")
            startDiscovery()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in
                    Log.write("camera access request -> \(granted)")
                    if granted {
                        self.startDiscovery()
                    } else {
                        self.status = .accessDenied
                    }
                }
            }
        default:
            Log.write("camera access denied/restricted")
            status = .accessDenied
        }
    }

    /// Opt in to CoreMediaIO "screen capture" devices so iOS devices show up
    /// as AVCaptureDevices. Without this flag they are invisible.
    private static func allowScreenCaptureDevices() {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var allow: UInt32 = 1
        let result = CMIOObjectSetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject), &address,
            0, nil, UInt32(MemoryLayout<UInt32>.size), &allow)
        Log.write("allowScreenCaptureDevices -> \(result)")
    }

    private static func isIPhoneScreenDevice(_ device: AVCaptureDevice) -> Bool {
        // The mirrored iPhone screen is the external device carrying a muxed
        // (video+audio) stream; Continuity Camera and webcams are plain video.
        device.hasMediaType(.muxed)
    }

    // MARK: - Discovery

    private func startDiscovery() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external], mediaType: nil, position: .unspecified)
        self.discovery = discovery

        discoveryObservation = discovery.observe(\.devices, options: [.initial, .new]) { _, _ in
            Task { @MainActor in self.attachIfPossible() }
        }

        // Belt and braces: the KVO above doesn't always fire when the DAL
        // device materializes, so poll while unattached.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in self.attachIfPossible() }
        }

        attachIfPossible()
    }

    private func attachIfPossible() {
        updateModelIdentifier()
        guard device == nil, let discovery else { return }
        if let phone = discovery.devices.first(where: Self.isIPhoneScreenDevice) {
            attach(phone)
        }
    }

    private func updateModelIdentifier() {
        let sibling = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external, .continuityCamera], mediaType: .video,
            position: .unspecified
        ).devices.first { $0.modelID.hasPrefix("iPhone") }
        if modelIdentifier != sibling?.modelID {
            modelIdentifier = sibling?.modelID
            Log.write("model identifier -> \(sibling?.modelID ?? "unknown")")
        }
    }

    @objc private func deviceWasDisconnected(_ note: Notification) {
        guard let gone = note.object as? AVCaptureDevice else { return }
        Task { @MainActor in
            guard gone == self.device else { return }
            Log.write("device disconnected: \(gone.localizedName)")
            self.detach()
        }
    }

    @objc private func sessionRuntimeError(_ note: Notification) {
        let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
        Log.write("session runtime error: \(error?.localizedDescription ?? "unknown") (\(error?.code ?? 0))")
    }

    @objc private func portFormatChanged(_ note: Notification) {
        guard let port = note.object as? AVCaptureInput.Port,
              port.mediaType == .video,
              let desc = port.formatDescription
        else { return }
        let dims = CMVideoFormatDescriptionGetDimensions(desc)
        Log.write("port format -> \(dims.width)x\(dims.height)")
        guard dims.width > 0, dims.height > 0 else { return }
        Task { @MainActor in
            self.streamSize = CGSize(width: CGFloat(dims.width), height: CGFloat(dims.height))
        }
    }

    // MARK: - Session

    private func attach(_ device: AVCaptureDevice) {
        Log.write("attaching \(device.localizedName) modelID=\(device.modelID) uid=\(device.uniqueID)")
        self.device = device
        deviceName = device.localizedName

        formatObservation = device.observe(\.activeFormat, options: [.initial, .new]) { device, _ in
            let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            Log.write("activeFormat -> \(dims.width)x\(dims.height)")
            guard dims.width > 0, dims.height > 0 else { return }
            Task { @MainActor in
                self.streamSize = CGSize(width: CGFloat(dims.width), height: CGFloat(dims.height))
            }
        }

        let session = self.session
        let videoOutput = self.videoOutput
        let frameQueue = self.frameQueue
        sessionQueue.async {
            var failure: String?
            session.beginConfiguration()
            session.inputs.forEach(session.removeInput)
            do {
                let input = try AVCaptureDeviceInput(device: device)
                if session.canAddInput(input) {
                    session.addInput(input)
                } else {
                    failure = "canAddInput returned false"
                }
            } catch {
                failure = "AVCaptureDeviceInput failed: \(error.localizedDescription)"
            }
            // Frame tap for screenshots/recording; BGRA for direct CoreImage use.
            if session.outputs.isEmpty {
                videoOutput.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                ]
                videoOutput.alwaysDiscardsLateVideoFrames = true
                videoOutput.setSampleBufferDelegate(self, queue: frameQueue)
                if session.canAddOutput(videoOutput) {
                    session.addOutput(videoOutput)
                } else {
                    Log.write("frame tap: canAddOutput returned false")
                }
            }
            session.commitConfiguration()

            if failure == nil {
                if !session.isRunning { session.startRunning() }
                Log.write("session running=\(session.isRunning) inputs=\(session.inputs.count)")
                if !session.isRunning { failure = "session failed to start" }
            }

            Task { @MainActor in
                if let failure {
                    Log.write("attach FAILED: \(failure)")
                    self.status = .error(failure)
                    self.device = nil
                } else {
                    self.status = .streaming
                }
            }
        }
    }

    private func detach() {
        device = nil
        deviceName = nil
        streamSize = nil
        modelIdentifier = nil
        formatObservation = nil
        status = .waitingForDevice
        media.stopRecording()

        let session = self.session
        sessionQueue.async {
            session.beginConfiguration()
            session.inputs.forEach(session.removeInput)
            session.commitConfiguration()
        }
    }
}

extension CaptureController: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            latestFrameLock.lock()
            _latestFrame = buffer
            latestFrameLock.unlock()

            frameCounter += 1
            if frameCounter % 15 == 0 {
                analyzeIslandRegion(buffer)
            }
        }
        media.ingest(sampleBuffer)
    }

    /// Checks whether the island region of the frame is predominantly black
    /// (= the stream is rendering the island itself). Runs on the frame queue;
    /// samples ~600 pixels, so it's effectively free.
    private nonisolated func analyzeIslandRegion(_ buffer: CVPixelBuffer) {
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        guard h > w, // portrait only
              let island = DynamicIsland.rect(streamSize: CGSize(width: w, height: h))
        else { return }

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let ptr = base.assumingMemoryBound(to: UInt8.self)

        // Sample the pill's core (inset to avoid anti-aliased edges).
        let core = island.insetBy(dx: island.width * 0.15, dy: island.height * 0.15)
        var dark = 0, total = 0
        var y = Int(core.minY)
        while y < Int(core.maxY) {
            var x = Int(core.minX)
            while x < Int(core.maxX) {
                let p = ptr + y * bytesPerRow + x * 4 // BGRA
                if p[0] < 30, p[1] < 30, p[2] < 30 { dark += 1 }
                total += 1
                x += 8
            }
            y += 8
        }
        guard total > 0 else { return }
        let showsIsland = Double(dark) / Double(total) > 0.7

        // Hysteresis: flip only after two consecutive agreeing samples.
        if pendingIslandResult.value == showsIsland {
            pendingIslandResult.streak += 1
        } else {
            pendingIslandResult = (showsIsland, 1)
        }
        guard pendingIslandResult.streak >= 2 else { return }

        latestFrameLock.lock()
        let changed = _islandInStream != showsIsland
        _islandInStream = showsIsland
        latestFrameLock.unlock()
        if changed {
            Task { @MainActor in self.streamShowsIsland = showsIsland }
        }
    }
}

/// Geometry of the Dynamic Island in stream pixels. All island iPhones are
/// 3x devices with the same island size in points (~126×37pt, 11pt from the
/// top), so pixel dimensions are constant.
enum DynamicIsland {
    /// "auto" fills the island when the stream omits it, "always" draws the
    /// pill unconditionally (calibration aid), "off" never draws it.
    static var mode: String {
        UserDefaults.standard.string(forKey: "islandMode") ?? "auto"
    }

    // Calibratable via ⌥-arrow shortcuts in the app; persisted in defaults.
    static var width: CGFloat { stored("islandWidth", default: 378) }
    static var height: CGFloat { stored("islandHeight", default: 111) }
    static var top: CGFloat { stored("islandY", default: 41) }

    private static func stored(_ key: String, default value: Double) -> CGFloat {
        CGFloat(UserDefaults.standard.object(forKey: key) as? Double ?? value)
    }

    /// Portrait-stream island rect (top-based y), or nil for non-island models.
    static func rect(streamSize: CGSize) -> CGRect? {
        guard PhoneModel.infer(from: streamSize).bezel == .dynamicIsland,
              streamSize.height > streamSize.width
        else { return nil }
        return CGRect(
            x: (streamSize.width - width) / 2, y: top,
            width: width, height: height)
    }
}
