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

    let session = AVCaptureSession()

    private var device: AVCaptureDevice?
    private var formatObservation: NSKeyValueObservation?
    private var discovery: AVCaptureDevice.DiscoverySession?
    private var discoveryObservation: NSKeyValueObservation?
    private var pollTimer: Timer?
    private let sessionQueue = DispatchQueue(label: "de.consti.present.capture")

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
        guard device == nil, let discovery else { return }
        if let phone = discovery.devices.first(where: Self.isIPhoneScreenDevice) {
            attach(phone)
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
        formatObservation = nil
        status = .waitingForDevice

        let session = self.session
        sessionQueue.async {
            session.beginConfiguration()
            session.inputs.forEach(session.removeInput)
            session.commitConfiguration()
        }
    }
}
