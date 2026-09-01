import AppKit
import CoreImage

/// Everything needed to draw the composed scene (background + frame + video)
/// independent of SwiftUI, at native stream resolution.
struct SceneSpec {
    let streamSize: CGSize // px, as delivered (may be landscape)
    let chrome: DeviceChrome?
    let fallbackStyle: BezelStyle
    let showBezel: Bool
    let backgroundPresetID: Int
    let backgroundImagePath: String
}

struct SceneGeometry {
    let canvas: CGSize     // px, even integers
    let outerRect: CGRect  // phone incl. frame, px (bottom-left origin)
    let screenRect: CGRect // video area, px — same size as the stream

    init(spec: SceneSpec) {
        let s = spec.streamSize
        let landscape = s.width > s.height

        // Fraction of the phone's outer box occupied by the screen.
        var fracOrigin = CGPoint.zero
        var fracSize = CGSize(width: 1, height: 1)
        if spec.showBezel {
            if let chrome = spec.chrome {
                let portraitAspect = landscape ? s.height / s.width : s.width / s.height
                let f = chrome.screenFraction(portraitAspect: portraitAspect)
                if landscape {
                    fracOrigin = CGPoint(x: f.minY, y: f.minX)
                    fracSize = CGSize(width: f.height, height: f.width)
                } else {
                    fracOrigin = f.origin
                    fracSize = f.size
                }
            } else {
                // Drawn-bezel fallback: uniform border of 5% of the short side.
                let border = 0.05 * min(s.width, s.height)
                fracOrigin = CGPoint(x: border / (s.width + 2 * border), y: border / (s.height + 2 * border))
                fracSize = CGSize(
                    width: s.width / (s.width + 2 * border),
                    height: s.height / (s.height + 2 * border))
            }
        }

        let outer = CGSize(width: s.width / fracSize.width, height: s.height / fracSize.height)
        let margin = (0.07 * min(outer.width, outer.height)).rounded()
        var canvasW = (outer.width + 2 * margin).rounded()
        var canvasH = (outer.height + 2 * margin).rounded()
        canvasW += canvasW.truncatingRemainder(dividingBy: 2)
        canvasH += canvasH.truncatingRemainder(dividingBy: 2)
        canvas = CGSize(width: canvasW, height: canvasH)

        let outerOrigin = CGPoint(
            x: ((canvasW - outer.width) / 2).rounded(),
            y: ((canvasH - outer.height) / 2).rounded())
        outerRect = CGRect(origin: outerOrigin, size: outer)
        screenRect = CGRect(
            x: (outerOrigin.x + fracOrigin.x * outer.width).rounded(),
            y: (outerOrigin.y + fracOrigin.y * outer.height).rounded(),
            width: s.width, height: s.height)
    }
}

/// Builds the static layers of the scene as CGImages (bottom-left origin,
/// pixel units) and composes video frames onto them via CoreImage (GPU).
final class SceneRenderer {
    let geometry: SceneGeometry
    private let baseImage: CIImage   // background + frame
    private let maskImage: CIImage   // white where video shows through
    private let videoTransform: CGAffineTransform
    private let ciContext: CIContext

    init?(spec: SceneSpec, ciContext: CIContext) {
        self.ciContext = ciContext
        let geo = SceneGeometry(spec: spec)
        geometry = geo
        guard let base = Self.renderBase(spec: spec, geo: geo),
              let mask = Self.renderMask(spec: spec, geo: geo)
        else { return nil }
        baseImage = CIImage(cgImage: base)
        maskImage = CIImage(cgImage: mask)
        videoTransform = CGAffineTransform(
            translationX: geo.screenRect.minX, y: geo.screenRect.minY)
    }

    /// Composes one video frame over the base scene. Returns nil on failure.
    func compose(_ videoFrame: CVPixelBuffer) -> CIImage? {
        let video = CIImage(cvPixelBuffer: videoFrame).transformed(by: videoTransform)
        guard let filter = CIFilter(name: "CIBlendWithMask") else { return nil }
        filter.setValue(video, forKey: kCIInputImageKey)
        filter.setValue(baseImage, forKey: kCIInputBackgroundImageKey)
        filter.setValue(maskImage, forKey: kCIInputMaskImageKey)
        return filter.outputImage?.cropped(to: CGRect(origin: .zero, size: geometry.canvas))
    }

    func composeCGImage(_ videoFrame: CVPixelBuffer) -> CGImage? {
        guard let output = compose(videoFrame) else { return nil }
        return ciContext.createCGImage(output, from: CGRect(origin: .zero, size: geometry.canvas))
    }

    func render(_ videoFrame: CVPixelBuffer, to target: CVPixelBuffer) {
        guard let output = compose(videoFrame) else { return }
        ciContext.render(output, to: target)
    }

    // MARK: - Static layers

    private static func makeContext(_ size: CGSize) -> CGContext? {
        CGContext(
            data: nil, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    private static func renderBase(spec: SceneSpec, geo: SceneGeometry) -> CGImage? {
        guard let ctx = makeContext(geo.canvas) else { return nil }
        ctx.interpolationQuality = .high
        drawBackground(spec: spec, canvas: geo.canvas, in: ctx)

        if spec.showBezel {
            let landscape = spec.streamSize.width > spec.streamSize.height
            if let chrome = spec.chrome,
               let chromeImg = rasterize(
                    chrome.composite, pixelSize: geo.outerRect.size, rotated90: landscape) {
                // soft drop shadow behind the phone
                ctx.saveGState()
                ctx.setShadow(
                    offset: CGSize(width: 0, height: -geo.canvas.height * 0.01),
                    blur: min(geo.canvas.width, geo.canvas.height) * 0.05,
                    color: CGColor(gray: 0, alpha: 0.45))
                ctx.draw(chromeImg, in: geo.outerRect)
                ctx.restoreGState()
            } else {
                drawFallbackBezel(spec: spec, geo: geo, in: ctx)
            }
        }
        return ctx.makeImage()
    }

    private static func renderMask(spec: SceneSpec, geo: SceneGeometry) -> CGImage? {
        guard let ctx = makeContext(geo.canvas) else { return nil }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: geo.canvas))

        let landscape = spec.streamSize.width > spec.streamSize.height
        if spec.showBezel, let chrome = spec.chrome, let mask = chrome.mask,
           let maskImg = rasterize(mask, pixelSize: geo.screenRect.size, rotated90: landscape) {
            ctx.saveGState()
            ctx.clip(to: geo.screenRect, mask: maskImg)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(geo.screenRect)
            ctx.restoreGState()
        } else {
            let radius = spec.showBezel
                ? min(geo.screenRect.width, geo.screenRect.height)
                    * (spec.fallbackStyle == .homeButton ? 0.015 : 0.12)
                : min(geo.screenRect.width, geo.screenRect.height) * 0.04
            let path = CGPath(
                roundedRect: geo.screenRect, cornerWidth: radius, cornerHeight: radius,
                transform: nil)
            ctx.addPath(path)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fillPath()
        }
        return ctx.makeImage()
    }

    private static func drawBackground(spec: SceneSpec, canvas: CGSize, in ctx: CGContext) {
        if spec.backgroundPresetID == -1,
           let nsImage = NSImage(contentsOfFile: spec.backgroundImagePath),
           nsImage.size.width > 0 {
            // scaled-to-fill
            let scale = max(canvas.width / nsImage.size.width, canvas.height / nsImage.size.height)
            let drawSize = CGSize(width: nsImage.size.width * scale, height: nsImage.size.height * scale)
            if let img = rasterize(nsImage, pixelSize: drawSize) {
                ctx.draw(img, in: CGRect(
                    x: (canvas.width - drawSize.width) / 2,
                    y: (canvas.height - drawSize.height) / 2,
                    width: drawSize.width, height: drawSize.height))
                return
            }
        }
        let preset = BackgroundPreset.preset(max(spec.backgroundPresetID, 0))
        let colors = preset.cgColors as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: nil) {
            // topLeading → bottomTrailing (bottom-left origin: top is maxY)
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: canvas.height),
                end: CGPoint(x: canvas.width, y: 0),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
    }

    private static func drawFallbackBezel(spec: SceneSpec, geo: SceneGeometry, in ctx: CGContext) {
        let outer = geo.outerRect
        let radius = min(outer.width, outer.height) * 0.17
        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: -geo.canvas.height * 0.01),
            blur: min(geo.canvas.width, geo.canvas.height) * 0.05,
            color: CGColor(gray: 0, alpha: 0.45))
        let path = CGPath(
            roundedRect: outer, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(CGColor(red: 0.16, green: 0.16, blue: 0.17, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()

        // The mirrored stream already contains the Dynamic Island / notch
        // pixels, so nothing is drawn over the video.
    }
}
