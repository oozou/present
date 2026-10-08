import AVFoundation
import AppKit
import CoreImage
import SwiftUI
import UniformTypeIdentifiers

/// A looping, muted video wallpaper. One shared player feeds both the live
/// window (through an AVPlayerLayer) and the exporters (through a video
/// output), so recordings, screenshots and the virtual camera show the same
/// frame as the window.
final class VideoBackground {
    static let shared = VideoBackground()

    let player = AVPlayer()
    private let lock = NSLock()
    private var output: AVPlayerItemVideoOutput?
    private var lastBuffer: CVPixelBuffer?
    private var endObserver: NSObjectProtocol?
    private(set) var currentURL: URL?

    private init() {
        player.isMuted = true
        player.actionAtItemEnd = .none
    }

    /// Starts looping `url` (no-op if it's already playing).
    func setSource(_ url: URL) {
        lock.lock()
        let same = currentURL == url
        lock.unlock()
        guard !same else { player.play(); return }

        let item = AVPlayerItem(url: url)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        item.add(output)

        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            self?.player.seek(to: .zero)
            self?.player.play()
        }

        lock.lock()
        self.output = output
        self.lastBuffer = nil
        self.currentURL = url
        lock.unlock()

        player.replaceCurrentItem(with: item)
        player.play()
        Log.write("video background: \(url.lastPathComponent)")
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        lock.lock()
        output = nil
        lastBuffer = nil
        currentURL = nil
        lock.unlock()
    }

    /// The current frame scaled to fill `canvas` (cropped), or nil if nothing
    /// is playing yet. Safe to call from any thread.
    func canvasImage(canvas: CGSize) -> CIImage? {
        lock.lock()
        let output = self.output
        let cached = lastBuffer
        lock.unlock()
        guard let output else { return nil }

        var buffer = cached
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        if output.hasNewPixelBuffer(forItemTime: time),
           let fresh = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
            buffer = fresh
            lock.lock(); lastBuffer = fresh; lock.unlock()
        }
        guard let buffer else { return nil }

        let image = CIImage(cvPixelBuffer: buffer)
        let scale = max(canvas.width / image.extent.width, canvas.height / image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let dx = (canvas.width - scaled.extent.width) / 2 - scaled.extent.minX
        let dy = (canvas.height - scaled.extent.height) / 2 - scaled.extent.minY
        return scaled
            .transformed(by: CGAffineTransform(translationX: dx, y: dy))
            .cropped(to: CGRect(origin: .zero, size: canvas))
    }

    static func isVideo(path: String) -> Bool {
        guard let type = UTType(filenameExtension: (path as NSString).pathExtension) else { return false }
        return type.conforms(to: .movie)
    }
}

// MARK: - Live view

/// Fills the window with the shared player, scaled to fill.
struct VideoBackgroundView: View {
    /// The wallpaper's primary file. Sonoma-style pairs have a portrait twin.
    let path: String

    var body: some View {
        GeometryReader { geo in
            PlayerLayerView(player: VideoBackground.shared.player)
                .task(id: Self.variant(of: path, portrait: geo.size.height > geo.size.width)) {
                    VideoBackground.shared.setSource(
                        URL(fileURLWithPath: Self.variant(of: path, portrait: geo.size.height > geo.size.width)))
                }
        }
        .background(Color.black)
        .ignoresSafeArea()
    }

    /// "… Landscape.mov" ↔ "… Portrait.mov", when the twin exists.
    static func variant(of path: String, portrait: Bool) -> String {
        let (from, to) = portrait ? ("Landscape", "Portrait") : ("Portrait", "Landscape")
        guard path.contains(from) else { return path }
        let twin = path.replacingOccurrences(of: from, with: to)
        return FileManager.default.fileExists(atPath: twin) ? twin : path
    }
}

private struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspectFill
        view.layer = layer
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Library

struct VideoWallpaper: Identifiable {
    let name: String
    /// Primary file (the landscape variant when there are two).
    let url: URL
    var id: String { url.path }
}

enum VideoWallpapers {
    /// Videos that ship with macOS plus any aerials downloaded for this user.
    static let all: [VideoWallpaper] = load()

    private static func load() -> [VideoWallpaper] {
        let fm = FileManager.default
        var result: [VideoWallpaper] = []

        let sonoma = URL(fileURLWithPath: "/System/Library/Desktop Pictures/.wallpapers/Sonoma")
        for name in ["Sonoma Graphic Light", "Sonoma Graphic Dark"] {
            let url = sonoma.appendingPathComponent("\(name) Landscape.mov")
            if fm.fileExists(atPath: url.path) {
                result.append(VideoWallpaper(name: name, url: url))
            }
        }

        let aerials = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/aerials/videos")
        let files = (try? fm.contentsOfDirectory(at: aerials, includingPropertiesForKeys: nil)) ?? []
        for (index, url) in files.filter({ $0.pathExtension.lowercased() == "mov" }).enumerated() {
            result.append(VideoWallpaper(name: "Aerial \(index + 1)", url: url))
        }
        return result
    }
}
