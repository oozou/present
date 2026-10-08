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
    /// Live preview. Frames from the video tap are retimed to "now" and shown
    /// immediately; AVCaptureVideoPreviewLayer adds noticeable lag on iPhone
    /// screen devices (it syncs to the session clock).
    nonisolated(unsafe) let displayLayer = AVSampleBufferDisplayLayer()

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
    nonisolated(unsafe) private var loggedFormat = false
    nonisolated(unsafe) private var _islandInStream = false
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
            // Frame tap for screenshots/recording/island detection. Deliberately
            // no videoSettings: requesting BGRA forces a per-frame conversion in
            // the capture pipeline, adding latency to the preview. CoreImage
            // and the island scan both accept the device's native format.
            if session.outputs.isEmpty {
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

            // Every frame — the scan touches ~600 pixels, so it's effectively
            // free, and per-frame detection keeps the overlay handoff seamless.
            analyzeIslandRegion(buffer)
        }
        display(sampleBuffer)
        media.ingest(sampleBuffer)
    }

    /// Re-stamps the frame with the current host time and tells the layer to
    /// show it immediately, bypassing its timebase scheduling.
    private nonisolated func display(_ sampleBuffer: CMSampleBuffer) {
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid)
        var retimed: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil, sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleBufferOut: &retimed)
        guard let retimed else { return }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            retimed, createIfNecessary: true) as? [NSMutableDictionary] {
            attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
        }

        if displayLayer.status == .failed { displayLayer.flush() }
        if displayLayer.isReadyForMoreMediaData {
            displayLayer.enqueue(retimed)
        }
    }

    private nonisolated static func fourCC(_ code: OSType) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xFF) }
        return String(bytes: bytes, encoding: .ascii) ?? String(code)
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

        let format = CVPixelBufferGetPixelFormatType(buffer)
        if !loggedFormat {
            loggedFormat = true
            Log.write("frame tap pixel format: \(Self.fourCC(format)) \(w)x\(h)")
        }

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        // Locate pixels without assuming a format: planar YUV → luma plane,
        // packed 4:2:2 → luma bytes, BGRA → all three channels.
        let base: UnsafeMutableRawPointer?
        let bytesPerRow: Int
        let bytesPerPixel: Int
        switch format {
        case kCVPixelFormatType_32BGRA:
            base = CVPixelBufferGetBaseAddress(buffer)
            bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            bytesPerPixel = 4
        case kCVPixelFormatType_422YpCbCr8, kCVPixelFormatType_422YpCbCr8_yuvs:
            // 2vuy = Cb Y Cr Y, yuvs = Y Cb Y Cr
            base = CVPixelBufferGetBaseAddress(buffer).map {
                format == kCVPixelFormatType_422YpCbCr8 ? $0 + 1 : $0
            }
            bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            bytesPerPixel = 2
        default:
            guard CVPixelBufferIsPlanar(buffer) else { return }
            base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)
            bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            bytesPerPixel = 1
        }
        guard let base else { return }
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        let isBGRA = format == kCVPixelFormatType_32BGRA

        // Sample the pill's core (inset to avoid anti-aliased edges).
        // Luma threshold is looser than the BGRA one: video-range black is 16.
        let core = island.insetBy(dx: island.width * 0.15, dy: island.height * 0.15)
        var dark = 0, total = 0
        var y = Int(core.minY)
        while y < Int(core.maxY) {
            var x = Int(core.minX)
            while x < Int(core.maxX) {
                let p = ptr + y * bytesPerRow + x * bytesPerPixel
                if isBGRA {
                    if p[0] < 30, p[1] < 30, p[2] < 30 { dark += 1 }
                } else if p[0] < 34 {
                    dark += 1
                }
                total += 1
                x += 8
            }
            y += 8
        }
        guard total > 0 else { return }
        let showsIsland = Double(dark) / Double(total) > 0.7

        // Hysteresis: flip only after three consecutive agreeing frames (~50ms).
        if pendingIslandResult.value == showsIsland {
            pendingIslandResult.streak += 1
        } else {
            pendingIslandResult = (showsIsland, 1)
        }
        guard pendingIslandResult.streak >= 3 else { return }

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
