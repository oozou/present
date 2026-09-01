import AppKit

/// Photoreal device frame artwork from Xcode's Simulator (DeviceKit).
/// `PhoneComposite.pdf` is the full vector frame; the framebuffer-mask PDF is
/// the exact screen shape. Both are optional system resources — when they're
/// missing (no Xcode/simulators installed) callers fall back to a drawn bezel.
struct DeviceChrome {
    let composite: NSImage
    let mask: NSImage?
    /// Composite media-box size in points.
    let compositeSize: CGSize

    private static let deviceKitRoot = "/Library/Developer/DeviceKit"
    private static let profilesRoot = "/Library/Developer/CoreSimulator/Profiles/DeviceTypes"

    /// The screen sits centered in the composite with the same inset on all
    /// sides. Solving (W-2i)/(H-2i) = aspect gives that inset, so no per-model
    /// screen-size table is needed.
    /// - Parameter portraitAspect: stream width/height in portrait orientation (< 1).
    func screenFraction(portraitAspect a: CGFloat) -> CGRect {
        let w = compositeSize.width, h = compositeSize.height
        let inset = (w - a * h) / (2 * (1 - a))
        guard inset > 0, inset * 2 < w else {
            return CGRect(x: 0.04, y: 0.04, width: 0.92, height: 0.92)
        }
        return CGRect(
            x: inset / w, y: inset / h,
            width: (w - 2 * inset) / w, height: (h - 2 * inset) / h)
    }

    // MARK: - Loading

    private static var cache: [String: DeviceChrome?] = [:]
    private static let cacheLock = NSLock()

    /// modelIdentifier ("iPhone18,2") → framebuffer mask UUID, from simulator profiles.
    private static let maskMap: [String: String] = {
        var map: [String: String] = [:]
        let fm = FileManager.default
        for entry in (try? fm.contentsOfDirectory(atPath: profilesRoot)) ?? [] {
            let plist = "\(profilesRoot)/\(entry)/Contents/Resources/profile.plist"
            guard let dict = NSDictionary(contentsOfFile: plist),
                  let model = dict["modelIdentifier"] as? String,
                  let mask = dict["framebufferMask"] as? String
            else { continue }
            map[model] = mask
        }
        return map
    }()

    static func load(modelIdentifier: String) -> DeviceChrome? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = cache[modelIdentifier] { return cached }
        let built = build(modelIdentifier: modelIdentifier)
        cache[modelIdentifier] = built
        return built
    }

    private static func build(modelIdentifier: String) -> DeviceChrome? {
        guard let map = NSDictionary(contentsOfFile: "\(deviceKitRoot)/chrome_map.plist"),
              let entry = map[modelIdentifier] as? [String: Any],
              let chromeID = entry["ChromeIdentifier"] as? String,
              let shortName = chromeID.components(separatedBy: ".").last
        else {
            Log.write("chrome: no mapping for \(modelIdentifier)")
            return nil
        }
        let resources = "\(deviceKitRoot)/Chrome/\(shortName).devicechrome/Contents/Resources"
        guard let composite = NSImage(contentsOfFile: "\(resources)/PhoneComposite.pdf"),
              composite.size.width > 0
        else {
            Log.write("chrome: \(shortName) has no composite")
            return nil
        }

        var mask: NSImage?
        if let maskUUID = maskMap[modelIdentifier] {
            mask = NSImage(contentsOfFile: "\(deviceKitRoot)/FramebufferMasks/\(maskUUID).pdf")
        }
        Log.write("chrome: loaded \(shortName) for \(modelIdentifier) (mask: \(mask != nil))")
        return DeviceChrome(composite: composite, mask: mask, compositeSize: composite.size)
    }
}

/// Rasterizes an NSImage (vector PDFs included) into a CGImage at an exact
/// pixel size, optionally rotated 90° for landscape use.
func rasterize(_ image: NSImage, pixelSize: CGSize, rotated90: Bool = false) -> CGImage? {
    let w = Int(pixelSize.width.rounded()), h = Int(pixelSize.height.rounded())
    guard w > 0, h > 0,
          let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.interpolationQuality = .high

    let drawSize = rotated90 ? CGSize(width: pixelSize.height, height: pixelSize.width) : pixelSize
    if rotated90 {
        ctx.translateBy(x: pixelSize.width / 2, y: pixelSize.height / 2)
        ctx.rotate(by: .pi / 2)
        ctx.translateBy(x: -drawSize.width / 2, y: -drawSize.height / 2)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    image.draw(
        in: CGRect(origin: .zero, size: drawSize),
        from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()
}
