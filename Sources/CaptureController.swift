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
    }

    @Published private(set) var status: Status = .waitingForDevice
    @Published private(set) var deviceName: String?
    /// Pixel dimensions of the incoming stream (portrait or landscape).
    @Published private(set) var streamSize: CGSize?

    let session = AVCaptureSession()

    private var device: AVCaptureDevice?
    private var formatObservation: NSKeyValueObservation?
    private let sessionQueue = DispatchQueue(label: "de.consti.present.capture")

    override init() {
        super.init()
        Self.allowScreenCaptureDevices()

        NotificationCenter.default.addObserver(
            self, selector: #selector(deviceWasConnected(_:)),
            name: AVCaptureDevice.wasConnectedNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(deviceWasDisconnected(_:)),
            name: AVCaptureDevice.wasDisconnectedNotification, object: nil)

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            attachFirstIPhone()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in
                    if granted {
                        self.attachFirstIPhone()
                    } else {
                        self.status = .accessDenied
                    }
                }
            }
        default:
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
        CMIOObjectSetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject), &address,
            0, nil, UInt32(MemoryLayout<UInt32>.size), &allow)
    }

    private static func isIPhoneScreenDevice(_ device: AVCaptureDevice) -> Bool {
        // The mirrored iPhone shows up as an external device carrying a muxed
        // (video+audio) stream; external webcams are plain video devices.
        device.hasMediaType(.muxed) || device.modelID.localizedCaseInsensitiveContains("iOS")
    }

    private func attachFirstIPhone() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external], mediaType: nil, position: .unspecified)
        if let phone = discovery.devices.first(where: Self.isIPhoneScreenDevice) {
            attach(phone)
        }
        // Otherwise wait: the DAL device usually appears a moment after the
        // allow-flag is set, delivered via wasConnectedNotification.
    }

    @objc private func deviceWasConnected(_ note: Notification) {
        guard let newDevice = note.object as? AVCaptureDevice,
              Self.isIPhoneScreenDevice(newDevice),
              AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        else { return }
        Task { @MainActor in
            if self.device == nil { self.attach(newDevice) }
        }
    }

    @objc private func deviceWasDisconnected(_ note: Notification) {
        guard let gone = note.object as? AVCaptureDevice else { return }
        Task { @MainActor in
            guard gone == self.device else { return }
            self.detach()
        }
    }

    private func attach(_ device: AVCaptureDevice) {
        self.device = device
        deviceName = device.localizedName

        formatObservation = device.observe(\.activeFormat, options: [.initial, .new]) { device, _ in
            let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            Task { @MainActor in
                self.streamSize = CGSize(width: CGFloat(dims.width), height: CGFloat(dims.height))
            }
        }

        let session = self.session
        sessionQueue.async {
            session.beginConfiguration()
            session.inputs.forEach(session.removeInput)
            if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                session.addInput(input)
            }
            session.commitConfiguration()
            if !session.isRunning { session.startRunning() }
            Task { @MainActor in self.status = .streaming }
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
