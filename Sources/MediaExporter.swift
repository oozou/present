import AVFoundation
import AppKit
import CoreImage

/// Saves screenshots (~/Pictures) and recordings (~/Movies) of the composed
/// scene at native stream resolution. Frames are pushed in from the capture
/// queue; composition happens on the GPU via SceneRenderer.
final class MediaExporter: ObservableObject {
    @Published private(set) var isRecording = false
    @Published var toast: String?

    private let ciContext = CIContext()
    private let lock = NSLock()

    // Recording state, guarded by `lock` (written from main, read from capture queue).
    private var renderer: SceneRenderer?
    private var islandOverlayActive: () -> Bool = { false }
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var sessionStarted = false
    private var lastPTS = CMTime.invalid
    private var recordingURL: URL?

    private static let timestamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f
    }()

    /// The system screenshot folder (what Screenshot.app configures via
    /// `com.apple.screencapture location`), falling back to the Desktop —
    /// the same rule macOS itself uses.
    private static var captureDirectory: URL {
        if let value = CFPreferencesCopyAppValue(
            "location" as CFString, "com.apple.screencapture" as CFString) as? String {
            let path = (value as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop", isDirectory: true)
    }

    // MARK: - Screenshot

    func saveScreenshot(spec: SceneSpec, frame: CVPixelBuffer, overlayIsland: Bool) {
        guard let renderer = SceneRenderer(spec: spec, ciContext: ciContext),
              let cgImage = renderer.composeCGImage(frame, overlayIsland: overlayIsland)
        else {
            showToast("Screenshot failed")
            return
        }
        let dir = Self.captureDirectory
        let url = dir.appendingPathComponent("Present \(Self.timestamp.string(from: Date())).png")
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            showToast("Screenshot failed")
            return
        }
        do {
            try data.write(to: url)
            Log.write("screenshot saved: \(url.path)")
            showToast("Screenshot saved to \(dir.lastPathComponent)")
        } catch {
            Log.write("screenshot write failed: \(error)")
            showToast("Screenshot failed")
        }
    }

    // MARK: - Recording

    func startRecording(spec: SceneSpec, islandOverlayActive: @escaping () -> Bool) {
        guard !isRecording else { return }
        guard let renderer = SceneRenderer(spec: spec, ciContext: ciContext) else {
            showToast("Recording failed to start")
            return
        }
        let size = renderer.geometry.canvas
        let url = Self.captureDirectory
            .appendingPathComponent("Present \(Self.timestamp.string(from: Date())).mov")
        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(size.width),
                AVVideoHeightKey: Int(size.height),
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: Int(size.width * size.height * 6),
                ],
            ])
            input.expectsMediaDataInRealTime = true
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: Int(size.width),
                    kCVPixelBufferHeightKey as String: Int(size.height),
                ])
            guard writer.canAdd(input) else {
                showToast("Recording failed to start")
                return
            }
            writer.add(input)
            guard writer.startWriting() else {
                Log.write("startWriting failed: \(String(describing: writer.error))")
                showToast("Recording failed to start")
                return
            }

            lock.lock()
            self.renderer = renderer
            self.islandOverlayActive = islandOverlayActive
            self.writer = writer
            self.writerInput = input
            self.adaptor = adaptor
            self.sessionStarted = false
            self.lastPTS = .invalid
            self.recordingURL = url
            lock.unlock()

            isRecording = true
            Log.write("recording started: \(url.path) canvas=\(size)")
        } catch {
            Log.write("recording start failed: \(error)")
            showToast("Recording failed to start")
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false

        lock.lock()
        let writer = self.writer
        let input = self.writerInput
        let url = self.recordingURL
        self.renderer = nil
        self.islandOverlayActive = { false }
        self.writer = nil
        self.writerInput = nil
        self.adaptor = nil
        self.recordingURL = nil
        lock.unlock()

        input?.markAsFinished()
        writer?.finishWriting {
            Task { @MainActor in
                if writer?.status == .completed {
                    Log.write("recording saved: \(url?.path ?? "?")")
                    let folder = url?.deletingLastPathComponent().lastPathComponent ?? "capture folder"
                    self.showToast("Recording saved to \(folder)")
                } else {
                    Log.write("recording failed: \(String(describing: writer?.error))")
                    self.showToast("Recording failed")
                }
            }
        }
    }

    /// Called from the capture queue for every incoming frame.
    func ingest(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        guard let renderer, let writer, let writerInput, let adaptor else {
            lock.unlock()
            return
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard let frame = CMSampleBufferGetImageBuffer(sampleBuffer),
              writer.status == .writing,
              writerInput.isReadyForMoreMediaData,
              pts != lastPTS
        else {
            lock.unlock()
            return
        }
        if !sessionStarted {
            writer.startSession(atSourceTime: pts)
            sessionStarted = true
        }
        lastPTS = pts

        var target: CVPixelBuffer?
        if let pool = adaptor.pixelBufferPool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &target)
        }
        if let target {
            renderer.render(frame, to: target, overlayIsland: islandOverlayActive())
            adaptor.append(target, withPresentationTime: pts)
        }
        lock.unlock()
    }

    private func showToast(_ message: String) {
        Task { @MainActor in
            self.toast = message
            try? await Task.sleep(for: .seconds(3))
            if self.toast == message { self.toast = nil }
        }
    }
}
