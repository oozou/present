import AppKit

/// Photoreal device frame artwork from Xcode's Simulator (DeviceKit).
/// `PhoneComposite.pdf` is the full vector frame; the framebuffer-mask PDF is
/// the exact screen shape. Both are optional system resources — when they're
/// missing (no Xcode/simulators installed) callers fall back to a drawn bezel.
/// A physical side button from the chrome bundle (volume, power, action).
/// Buttons are drawn *behind* the phone body with a protruding sliver.
/// chrome.json positions them in a space padded by `devicePadding` around the
/// composite, so composite-relative x can be negative (sticking out).
/// `restMinX` is the slid-out position (like a real phone), `tuckedMinX` the
/// pressed-in position; both are leading-edge x relative to the composite.
struct ChromeButton: Identifiable {
    let id: String
    let image: NSImage
    let imageDown: NSImage?
    let size: CGSize    // points
    let y: CGFloat      // offset from composite top, points
    let restMinX: CGFloat
    let tuckedMinX: CGFloat
}

struct DeviceChrome {
    let composite: NSImage
    let mask: NSImage?
    let buttons: [ChromeButton]
    /// Composite media-box size in points.
    let compositeSize: CGSize
    /// Simulator window padding around the composite (buttons protrude into it).
    let padding: NSEdgeInsets

    var paddedSize: CGSize {
        CGSize(
            width: compositeSize.width + padding.left + padding.right,
            height: compositeSize.height + padding.top + padding.bottom)
    }

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

    static func load(modelIdentifier: String, finish: String = DeviceFinish.original.id) -> DeviceChrome? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        let key = "\(modelIdentifier)|\(finish)"
        if let cached = cache[key] { return cached }
        let built: DeviceChrome?
        if finish == DeviceFinish.original.id {
            built = build(modelIdentifier: modelIdentifier)
        } else if let base = build(modelIdentifier: modelIdentifier) {
            built = base.tinted(DeviceFinish.named(finish))
        } else {
            built = nil
        }
        cache[key] = built
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
        let (buttons, padding) = loadButtons(
            resources: resources, compositeSize: composite.size)
        Log.write("chrome: loaded \(shortName) for \(modelIdentifier) (mask: \(mask != nil), buttons: \(buttons.count))")
        return DeviceChrome(
            composite: composite, mask: mask, buttons: buttons,
            compositeSize: composite.size, padding: padding)
    }

    private static func loadButtons(
        resources: String, compositeSize: CGSize
    ) -> ([ChromeButton], NSEdgeInsets) {
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
        struct Padding: Decodable {
            let top: CGFloat?; let left: CGFloat?
            let bottom: CGFloat?; let right: CGFloat?
        }
        struct Images: Decodable { let devicePadding: Padding? }
        struct ChromeJSON: Decodable { let inputs: [Input]?; let images: Images? }

        guard let data = FileManager.default.contents(atPath: "\(resources)/chrome.json"),
              let json = try? JSONDecoder().decode(ChromeJSON.self, from: data)
        else { return ([], NSEdgeInsets()) }

        let pad = json.images?.devicePadding
        let padding = NSEdgeInsets(
            top: pad?.top ?? 0, left: pad?.left ?? 0,
            bottom: pad?.bottom ?? 0, right: pad?.right ?? 0)
        // Padded-space width; button x offsets are measured in this space.
        let paddedWidth = compositeSize.width + padding.left + padding.right

        let buttons = (json.inputs ?? []).compactMap { input -> ChromeButton? in
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
            // Convert padded-space x to composite-relative leading-edge x.
            func minX(_ x: CGFloat) -> CGFloat {
                anchor == "left"
                    ? x - padding.left
                    : paddedWidth + x - image.size.width - padding.left
            }
            let restX = offsets.rollover?.x ?? offsets.normal.x
            return ChromeButton(
                id: input.name,
                image: image,
                imageDown: down,
                size: image.size,
                y: offsets.normal.y - padding.top,
                restMinX: minX(restX),
                tuckedMinX: minX(offsets.normal.x))
        }
        return (buttons, padding)
    }
}

extension DeviceChrome {
    /// Full frame — side buttons behind the body — rasterized at an exact
    /// pixel size, optionally rotated 90° for landscape use. Buttons are at
    /// their rest (slid-out) position. `pixelSize` covers `paddedSize`, so the
    /// composite body sits inset by the device padding.
    func frameImage(pixelSize: CGSize, rotated90: Bool = false) -> CGImage? {
        rasterizeCanvas(pixelSize: pixelSize, rotated90: rotated90) { drawRect in
            let scale = drawRect.width / paddedSize.width
            let padded = paddedSize
            for button in buttons {
                let rect = CGRect(
                    x: (padding.left + button.restMinX) * scale,
                    y: (padded.height - padding.top - button.y - button.size.height) * scale,
                    width: button.size.width * scale,
                    height: button.size.height * scale)
                button.image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            }
            composite.draw(
                in: CGRect(
                    x: padding.left * scale, y: padding.bottom * scale,
                    width: compositeSize.width * scale,
                    height: compositeSize.height * scale),
                from: .zero, operation: .sourceOver, fraction: 1)
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

// MARK: - Finishes

/// A recolor of the stock (graphite) simulator artwork. The bundles ship a
/// single finish, so others are made by colorizing the frame's luminance;
/// pure-black glass stays black, only the metal band takes the color.
struct DeviceFinish: Identifiable {
    let id: String
    let name: String
    /// nil = the artwork as shipped.
    let rgb: (Double, Double, Double)?
    /// Gamma applied before colorizing; lower lifts the dark metal more.
    let lift: Double

    static let original = DeviceFinish(id: "original", name: "Graphite", rgb: nil, lift: 1)

    static let all: [DeviceFinish] = [
        original,
        .init(id: "silver", name: "Silver", rgb: (0.86, 0.87, 0.89), lift: 0.35),
        .init(id: "natural", name: "Natural", rgb: (0.80, 0.76, 0.70), lift: 0.45),
        .init(id: "desert", name: "Desert", rgb: (0.84, 0.68, 0.54), lift: 0.50),
        .init(id: "blue", name: "Blue", rgb: (0.40, 0.52, 0.68), lift: 0.55),
        .init(id: "pink", name: "Pink", rgb: (0.90, 0.66, 0.72), lift: 0.50),
        .init(id: "white", name: "White", rgb: (0.96, 0.96, 0.95), lift: 0.30),
    ]

    static func named(_ id: String) -> DeviceFinish {
        all.first { $0.id == id } ?? original
    }
}

extension DeviceChrome {
    /// Copy of this chrome with the frame and button artwork recolored.
    func tinted(_ finish: DeviceFinish) -> DeviceChrome {
        guard let rgb = finish.rgb else { return self }
        let ctx = CIContext()
        func tint(_ image: NSImage) -> NSImage {
            // 4x the point size keeps the bitmap sharp when drawn big.
            let px = CGSize(width: image.size.width * 4, height: image.size.height * 4)
            guard let cg = rasterize(image, pixelSize: px) else { return image }
            let input = CIImage(cgImage: cg)
            let color = CIColor(red: rgb.0, green: rgb.1, blue: rgb.2)
            guard let gamma = CIFilter(name: "CIGammaAdjust", parameters: [
                      kCIInputImageKey: input, "inputPower": finish.lift]),
                  let mono = CIFilter(name: "CIColorMonochrome", parameters: [
                      kCIInputImageKey: gamma.outputImage as Any,
                      kCIInputColorKey: color, kCIInputIntensityKey: 1.0]),
                  let out = mono.outputImage,
                  let result = ctx.createCGImage(out, from: input.extent)
            else { return image }
            return NSImage(cgImage: result, size: image.size)
        }
        return DeviceChrome(
            composite: tint(composite), mask: mask,
            buttons: buttons.map {
                ChromeButton(
                    id: $0.id, image: tint($0.image), imageDown: $0.imageDown.map(tint),
                    size: $0.size, y: $0.y, restMinX: $0.restMinX, tuckedMinX: $0.tuckedMinX)
            },
            compositeSize: compositeSize, padding: padding)
    }
}
