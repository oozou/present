import SwiftUI
import ImageIO

struct BackgroundPreset: Identifiable {
    let id: Int
    let name: String
    let rgb: [(Double, Double, Double)]
    /// Solid colors are listed as swatches instead of gradient tiles.
    var isSolid = false

    var colors: [Color] { rgb.map { Color(red: $0.0, green: $0.1, blue: $0.2) } }
    var cgColors: [CGColor] { rgb.map { CGColor(red: $0.0, green: $0.1, blue: $0.2, alpha: 1) } }

    static let all: [BackgroundPreset] = [
        .init(id: 0, name: "Aurora", rgb: [(0.35, 0.20, 0.65), (0.10, 0.35, 0.70), (0.75, 0.30, 0.55)]),
        .init(id: 1, name: "Ocean", rgb: [(0.05, 0.25, 0.45), (0.05, 0.55, 0.60)]),
        .init(id: 2, name: "Sunset", rgb: [(0.95, 0.45, 0.25), (0.85, 0.25, 0.50)]),
        .init(id: 3, name: "Meadow", rgb: [(0.10, 0.45, 0.30), (0.30, 0.70, 0.55)]),
        .init(id: 4, name: "Graphite", rgb: [(0.28, 0.28, 0.28), (0.10, 0.10, 0.10)]),
        .init(id: 5, name: "Black", rgb: [(0, 0, 0), (0, 0, 0)], isSolid: true),
        .init(id: 6, name: "White", rgb: [(1.0, 1.0, 1.0), (0.88, 0.88, 0.88)], isSolid: true),
        // Subtle, low-saturation gradients. Ids are persisted in user defaults,
        // so only ever append.
        .init(id: 7, name: "Mist", rgb: [(0.86, 0.89, 0.93), (0.74, 0.80, 0.88)]),
        .init(id: 8, name: "Dusk", rgb: [(0.30, 0.30, 0.45), (0.55, 0.42, 0.55)]),
        .init(id: 9, name: "Sand", rgb: [(0.93, 0.88, 0.80), (0.84, 0.74, 0.66)]),
        .init(id: 10, name: "Sage", rgb: [(0.78, 0.85, 0.78), (0.58, 0.70, 0.66)]),
        .init(id: 11, name: "Blush", rgb: [(0.95, 0.84, 0.86), (0.84, 0.74, 0.84)]),
        .init(id: 12, name: "Slate", rgb: [(0.34, 0.39, 0.46), (0.17, 0.20, 0.26)]),
        .init(id: 13, name: "Lagoon", rgb: [(0.70, 0.86, 0.88), (0.50, 0.68, 0.80)]),
        .init(id: 14, name: "Lavender", rgb: [(0.82, 0.80, 0.93), (0.66, 0.70, 0.88)]),
        // Muted solid colors.
        .init(id: 15, name: "Teal", rgb: [(0.28, 0.47, 0.45)], isSolid: true),
        .init(id: 16, name: "Indigo", rgb: [(0.41, 0.41, 0.66)], isSolid: true),
        .init(id: 17, name: "Gold", rgb: [(0.78, 0.67, 0.44)], isSolid: true),
        .init(id: 18, name: "Rose", rgb: [(0.80, 0.50, 0.52)], isSolid: true),
    ]

    static var gradients: [BackgroundPreset] { all.filter { !$0.isSolid } }
    static var solids: [BackgroundPreset] { all.filter(\.isSolid) }

    static func preset(_ id: Int) -> BackgroundPreset {
        all.first { $0.id == id } ?? all[0]
    }
}

/// Selection ids outside the preset list.
enum BackgroundSelection {
    static let image = -1
    static let customColor = -2
    /// An animated background; `backgroundImagePath` holds the video file.
    static let video = -3
}

/// "#RRGGBB" <-> color helpers for the user's custom solid color.
enum BackgroundColor {
    static func nsColor(hex: String) -> NSColor? {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    static func hex(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

/// Renders the chosen background: a gradient/solid preset, a user-picked
/// image, or a custom color.
struct BackgroundView: View {
    let presetID: Int
    let imagePath: String
    let colorHex: String

    var body: some View {
        if presetID == BackgroundSelection.customColor,
           let color = BackgroundColor.nsColor(hex: colorHex) {
            Color(nsColor: color).ignoresSafeArea()
        } else if presetID == BackgroundSelection.video {
            VideoBackgroundView(path: imagePath)
        } else if presetID == BackgroundSelection.image {
            BackgroundImageView(path: imagePath)
        } else {
            gradient(presetID)
        }
    }

    private func gradient(_ id: Int) -> some View {
        LinearGradient(
            colors: BackgroundPreset.preset(id).colors,
            startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
    }
}

/// Decodes off the main thread into a downsampled, cached image. The body of
/// ContentView re-evaluates often, and decoding a multi-megapixel wallpaper
/// each time would stall the UI.
private struct BackgroundImageView: View {
    let path: String
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            // Shown while the image decodes, or if it can't be read.
            LinearGradient(
                colors: BackgroundPreset.preset(0).colors,
                startPoint: .topLeading, endPoint: .bottomTrailing)
            if let image {
                GeometryReader { geo in
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
            }
        }
        .ignoresSafeArea()
        .task(id: path) {
            image = await BackgroundImageCache.image(path: path)
        }
    }
}

enum BackgroundImageCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(path: String) async -> NSImage? {
        if let hit = cache.object(forKey: path as NSString) { return hit }
        let image = await Task.detached(priority: .userInitiated) {
            downsample(path: path)
        }.value
        if let image { cache.setObject(image, forKey: path as NSString) }
        return image
    }

    private nonisolated static func downsample(path: String) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 3000,
              ] as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }
}

/// Wallpapers that ship with macOS. Only the static images installed on disk
/// are listed; dynamic/aerial wallpapers are downloaded on demand and have no
/// stable file to point at.
struct SystemWallpaper: Identifiable {
    let name: String
    let url: URL
    /// Small preview (falls back to the image itself).
    let thumbnail: URL
    var id: String { url.path }
}

enum SystemWallpapers {
    static let all: [SystemWallpaper] = load()

    private static func load() -> [SystemWallpaper] {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/System/Library/Desktop Pictures")
        let hidden = root.appendingPathComponent(".wallpapers")
        let thumbs = root.appendingPathComponent(".thumbnails")

        func heics(in dir: URL, skipHidden: Bool = true) -> [URL] {
            let urls = (try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil,
                options: skipHidden ? .skipsHiddenFiles : [])) ?? []
            return urls.filter { $0.pathExtension.lowercased() == "heic" }
        }

        var files = heics(in: root)
        for dir in (try? fm.contentsOfDirectory(at: hidden, includingPropertiesForKeys: nil)) ?? [] {
            files += heics(in: dir)
        }

        let featured = ["Sonoma", "Sonoma Horizon", "Radial Sky Blue"]
        return files
            .map { url -> SystemWallpaper in
                let name = url.deletingPathExtension().lastPathComponent
                let thumb = thumbs.appendingPathComponent("\(name).heic")
                return SystemWallpaper(
                    name: name, url: url,
                    thumbnail: fm.fileExists(atPath: thumb.path) ? thumb : url)
            }
            .sorted {
                let a = featured.firstIndex(of: $0.name) ?? featured.count
                let b = featured.firstIndex(of: $1.name) ?? featured.count
                return a != b ? a < b : $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }
}
