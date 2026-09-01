import AppKit

/// Photoreal device frame artwork from Xcode's Simulator (DeviceKit).
/// `PhoneComposite.pdf` is the full vector frame; the framebuffer-mask PDF is
/// the exact screen shape. Both are optional system resources — when they're
/// missing (no Xcode/simulators installed) callers fall back to a drawn bezel.
/// A physical side button from the chrome bundle (volume, power, action).
/// Buttons are drawn *behind* the phone body; only the protruding sliver
/// shows. `restX` is the slid-out position (like a real phone), `tuckedX`
/// the pressed-in position.
struct ChromeButton: Identifiable {
    let id: String
    let image: NSImage
    let imageDown: NSImage?
    let size: CGSize // points
    let anchorLeft: Bool
    let y: CGFloat       // top-based offset in composite points
    let restX: CGFloat   // chrome.json "rollover" x
    let tuckedX: CGFloat // chrome.json "normal" x

    /// Leading-edge x in composite points at a given slide position.
    func minX(outerWidth: CGFloat, x: CGFloat) -> CGFloat {
        anchorLeft ? x : outerWidth + x - size.width
    }
}

struct DeviceChrome {
    let composite: NSImage
    let mask: NSImage?
    let buttons: [ChromeButton]
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
        let buttons = loadButtons(resources: resources)
        Log.write("chrome: loaded \(shortName) for \(modelIdentifier) (mask: \(mask != nil), buttons: \(buttons.count))")
        return DeviceChrome(
            composite: composite, mask: mask, buttons: buttons,
            compositeSize: composite.size)
    }

    private static func loadButtons(resources: String) -> [ChromeButton] {
        struct Point: Decodable { let x: CGFloat; let y: CGFloat }
        struct Offsets: Decodable { let normal: Point; let rollover: Point? }
        struct Input: Decodable {
            let name: String
            let type: String
            let image: String?
            let imageDown: String?
            let anchor: String?
            let offsets: Offsets?
        }
        struct ChromeJSON: Decodable { let inputs: [Input]? }

        guard let data = FileManager.default.contents(atPath: "\(resources)/chrome.json"),
              let json = try? JSONDecoder().decode(ChromeJSON.self, from: data)
        else { return [] }

        return (json.inputs ?? []).compactMap { input in
            guard input.type == "button",
                  let anchor = input.anchor, anchor == "left" || anchor == "right",
                  let imageName = input.image,
                  let image = NSImage(contentsOfFile: "\(resources)/\(imageName).pdf"),
                  image.size.width > 0,
                  let offsets = input.offsets
            else { return nil }
            let down = input.imageDown.flatMap {
                NSImage(contentsOfFile: "\(resources)/\($0).pdf")
            }
            return ChromeButton(
                id: input.name,
                image: image,
                imageDown: down,
                size: image.size,
                anchorLeft: anchor == "left",
                y: offsets.normal.y,
                restX: offsets.rollover?.x ?? offsets.normal.x,
                tuckedX: offsets.normal.x)
        }
    }
}

extension DeviceChrome {
    /// Full frame — side buttons behind the body — rasterized at an exact
    /// pixel size, optionally rotated 90° for landscape use. Buttons are at
    /// their rest (slid-out) position.
    func frameImage(pixelSize: CGSize, rotated90: Bool = false) -> CGImage? {
        rasterizeCanvas(pixelSize: pixelSize, rotated90: rotated90) { drawRect in
            let scale = drawRect.width / compositeSize.width
            for button in buttons {
                let minX = button.minX(outerWidth: compositeSize.width, x: button.restX)
                let rect = CGRect(
                    x: minX * scale,
                    y: drawRect.height - (button.y + button.size.height) * scale,
                    width: button.size.width * scale,
                    height: button.size.height * scale)
                button.image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            }
            composite.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1)
        }
    }
}

/// Rasterizes an NSImage (vector PDFs included) into a CGImage at an exact
/// pixel size, optionally rotated 90° for landscape use.
func rasterize(_ image: NSImage, pixelSize: CGSize, rotated90: Bool = false) -> CGImage? {
    rasterizeCanvas(pixelSize: pixelSize, rotated90: rotated90) { drawRect in
        image.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1)
    }
}

/// Creates a bitmap of `pixelSize`, optionally rotated 90°, and hands a
/// portrait-oriented rect to `draw` with an NSGraphicsContext current.
func rasterizeCanvas(
    pixelSize: CGSize, rotated90: Bool, draw: (CGRect) -> Void
) -> CGImage? {
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
    draw(CGRect(origin: .zero, size: drawSize))
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()
}
