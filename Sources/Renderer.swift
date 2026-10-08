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
    let backgroundColorHex: String
    var style = SceneStyle()

    var usesVideoBackground: Bool { backgroundPresetID == BackgroundSelection.video }
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

        var outer = CGSize(width: s.width / fracSize.width, height: s.height / fracSize.height)
        // Tilt and reflection need extra room around (and below) the phone.
        let margin = (0.07 * min(outer.width, outer.height)).rounded()
        let marginX: CGFloat, marginTop: CGFloat, marginBottom: CGFloat
        if spec.style.model3D {
            // The 3D phone can be turned, so leave room on every side.
            outer = CGSize(width: s.width / 0.93, height: s.height / 0.96)
            marginX = (outer.width * 0.30).rounded()
            marginTop = (outer.height * 0.09).rounded()
            marginBottom = marginTop
        } else if spec.style.needsPlane {
            marginX = (outer.width * (spec.style.isTilted ? 0.22 : 0.10)).rounded()
            marginTop = (outer.height * 0.06).rounded()
            marginBottom = (outer.height * (spec.style.reflection
                ? SceneStyle.reflectionDepth * 0.85 : 0.06)).rounded()
        } else {
            marginX = margin; marginTop = margin; marginBottom = margin
        }
        var canvasW = (outer.width + 2 * marginX).rounded()
        var canvasH = (outer.height + marginTop + marginBottom).rounded()
        canvasW += canvasW.truncatingRemainder(dividingBy: 2)
        canvasH += canvasH.truncatingRemainder(dividingBy: 2)
        canvas = CGSize(width: canvasW, height: canvasH)

        // Bottom-left origin: the bottom margin is the y offset.
        let outerOrigin = CGPoint(x: marginX, y: marginBottom)
        outerRect = CGRect(origin: outerOrigin, size: outer)
        screenRect = CGRect(
            x: (outerOrigin.x + fracOrigin.x * outer.width).rounded(),
            y: (outerOrigin.y + fracOrigin.y * outer.height).rounded(),
            width: s.width, height: s.height)
    }
}

/// Builds the static layers of the scene as CGImages (bottom-left origin,
/// pixel units) and composes video frames onto them via CoreImage (GPU).
///
/// Layer order, bottom to top: background, shadow, phone (frame with the video
/// in its screen). When tilt or reflection is on, the phone (and its
/// reflection) is first projected onto a rotated plane.
final class SceneRenderer {
    let geometry: SceneGeometry
    private let backgroundImage: CIImage
    private let frameLayer: CIImage    // transparent canvas holding just the frame
    private let shadowLayer: CIImage?
    private let maskImage: CIImage     // white where video shows through
    private let islandImage: CIImage?  // black pill, canvas-positioned
    private let videoTransform: CGAffineTransform
    private let plane: ProjectedPlane?
    private let animatedBackground: Bool
    private let model: ModelPhone?
    private let ciContext: CIContext

    init?(spec: SceneSpec, ciContext: CIContext) {
        self.ciContext = ciContext
        animatedBackground = spec.usesVideoBackground
        model = spec.style.model3D ? ModelPhone(spec: PhoneModelSpec.named(spec.style.modelID)) : nil
        let geo = SceneGeometry(spec: spec)
        geometry = geo
        guard let background = Self.renderBackground(spec: spec, geo: geo),
              let frame = Self.renderFrame(spec: spec, geo: geo),
              let mask = Self.renderMask(spec: spec, geo: geo)
        else { return nil }
        backgroundImage = CIImage(cgImage: background)
        frameLayer = CIImage(cgImage: frame)
        maskImage = CIImage(cgImage: mask)
        islandImage = Self.renderIsland(spec: spec, geo: geo).map(CIImage.init)
        videoTransform = CGAffineTransform(
            translationX: geo.screenRect.minX, y: geo.screenRect.minY)

        plane = spec.style.needsPlane
            ? ProjectedPlane(style: spec.style, geo: geo)
            : nil
        // The frame is static, so its (projected, blurred) shadow is rendered once.
        shadowLayer = spec.style.shadow && spec.showBezel
            ? Self.renderShadow(frame: CIImage(cgImage: frame), plane: plane, geo: geo, ciContext: ciContext)
            : nil
    }

    /// Composes one video frame over the scene. `overlayIsland` draws the
    /// black island pill (used while the stream doesn't render its own).
    /// `background` replaces the static background (animated backgrounds).
    func compose(
        _ videoFrame: CVPixelBuffer, overlayIsland: Bool, background: CIImage? = nil
    ) -> CIImage? {
        let canvasRect = CGRect(origin: .zero, size: geometry.canvas)
        if let model {
            // 3D model: SceneKit draws the whole phone (with the video on its
            // screen) onto a transparent canvas, which sits on the background.
            guard let phone = model.render(
                frame: videoFrame, overlayIsland: overlayIsland, canvas: geometry.canvas)
            else { return nil }
            let live = background
                ?? (animatedBackground ? VideoBackground.shared.canvasImage(canvas: geometry.canvas) : nil)
            return phone.composited(over: live ?? backgroundImage).cropped(to: canvasRect)
        }
        let video = CIImage(cvPixelBuffer: videoFrame).transformed(by: videoTransform)
        guard let filter = CIFilter(name: "CIBlendWithMask") else { return nil }
        filter.setValue(video, forKey: kCIInputImageKey)
        filter.setValue(frameLayer, forKey: kCIInputBackgroundImageKey)
        filter.setValue(maskImage, forKey: kCIInputMaskImageKey)
        guard var phone = filter.outputImage else { return nil }
        if overlayIsland, let islandImage {
            phone = islandImage.composited(over: phone)
        }

        if let plane {
            if let fade = plane.reflectionFade,
               let blend = CIFilter(name: "CIBlendWithMask") {
                // Mirror about the phone's bottom edge, fading out with distance.
                blend.setValue(phone.transformed(by: plane.flip), forKey: kCIInputImageKey)
                blend.setValue(
                    CIImage(color: .clear).cropped(to: canvasRect),
                    forKey: kCIInputBackgroundImageKey)
                blend.setValue(fade, forKey: kCIInputMaskImageKey)
                if let reflection = blend.outputImage {
                    phone = phone.composited(over: reflection)
                }
            }
            phone = plane.project(phone.cropped(to: canvasRect))
        }

        var output = phone
        if let shadowLayer { output = output.composited(over: shadowLayer) }
        // Animated backgrounds pull the shared player's current frame; until
        // the first frame arrives the static fallback shows.
        let live = background
            ?? (animatedBackground ? VideoBackground.shared.canvasImage(canvas: geometry.canvas) : nil)
        output = output.composited(over: live ?? backgroundImage)
        return output.cropped(to: canvasRect)
    }

    func composeCGImage(_ videoFrame: CVPixelBuffer, overlayIsland: Bool) -> CGImage? {
        guard let output = compose(videoFrame, overlayIsland: overlayIsland) else { return nil }
        return ciContext.createCGImage(output, from: CGRect(origin: .zero, size: geometry.canvas))
    }

    func render(
        _ videoFrame: CVPixelBuffer, to target: CVPixelBuffer, overlayIsland: Bool,
        background: CIImage? = nil
    ) {
        guard let output = compose(
            videoFrame, overlayIsland: overlayIsland, background: background)
        else { return }
        ciContext.render(output, to: target)
    }

    /// Transparent canvas with just the black island pill over the screen.
    private static func renderIsland(spec: SceneSpec, geo: SceneGeometry) -> CGImage? {
        guard let island = DynamicIsland.rect(streamSize: spec.streamSize),
              let ctx = makeContext(geo.canvas)
        else { return nil }
        // Convert top-based stream coords to bottom-left canvas coords.
        let rect = CGRect(
            x: geo.screenRect.minX + island.minX,
            y: geo.screenRect.maxY - island.minY - island.height,
            width: island.width, height: island.height)
        ctx.addPath(CGPath(
            roundedRect: rect, cornerWidth: rect.height / 2,
            cornerHeight: rect.height / 2, transform: nil))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fillPath()
        return ctx.makeImage()
    }

    /// Soft drop shadow of the frame silhouette (projected like the phone
    /// when tilted).
    private static func renderShadow(
        frame: CIImage, plane: ProjectedPlane?, geo: SceneGeometry, ciContext: CIContext
    ) -> CIImage? {
        let canvasRect = CGRect(origin: .zero, size: geo.canvas)
        var silhouette = frame.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.45),
        ])
        if let plane { silhouette = plane.project(silhouette.cropped(to: canvasRect)) }
        let sigma = min(geo.canvas.width, geo.canvas.height) * 0.025
        let blurred = silhouette
            .transformed(by: CGAffineTransform(translationX: 0, y: -geo.canvas.height * 0.01))
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: sigma])
            .cropped(to: canvasRect)
        guard let cg = ciContext.createCGImage(blurred, from: canvasRect) else { return nil }
        return CIImage(cgImage: cg)
    }

    // MARK: - Static layers

    private static func makeContext(_ size: CGSize) -> CGContext? {
        CGContext(
            data: nil, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    private static func renderBackground(spec: SceneSpec, geo: SceneGeometry) -> CGImage? {
        guard let ctx = makeContext(geo.canvas) else { return nil }
        ctx.interpolationQuality = .high
        drawBackground(spec: spec, canvas: geo.canvas, in: ctx)
        return ctx.makeImage()
    }

    /// The device frame on a transparent canvas (no shadow; that's a separate layer).
    private static func renderFrame(spec: SceneSpec, geo: SceneGeometry) -> CGImage? {
        guard let ctx = makeContext(geo.canvas) else { return nil }
        ctx.interpolationQuality = .high

        if spec.showBezel {
            let landscape = spec.streamSize.width > spec.streamSize.height
            // The frame image covers the padded size (buttons protrude beyond
            // the composite), so expand the draw rect accordingly.
            let padScaleW = (spec.chrome?.paddedSize.width ?? 1) / (spec.chrome?.compositeSize.width ?? 1)
            let padScaleH = (spec.chrome?.paddedSize.height ?? 1) / (spec.chrome?.compositeSize.height ?? 1)
            let expandedSize = landscape
                ? CGSize(
                    width: geo.outerRect.width * padScaleH,
                    height: geo.outerRect.height * padScaleW)
                : CGSize(
                    width: geo.outerRect.width * padScaleW,
                    height: geo.outerRect.height * padScaleH)
            let expandedRect = CGRect(
                x: geo.outerRect.midX - expandedSize.width / 2,
                y: geo.outerRect.midY - expandedSize.height / 2,
                width: expandedSize.width, height: expandedSize.height)
            if let chrome = spec.chrome,
               let chromeImg = chrome.frameImage(
                    pixelSize: expandedRect.size, rotated90: landscape) {
                ctx.draw(chromeImg, in: expandedRect)
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
        if spec.backgroundPresetID == BackgroundSelection.customColor,
           let color = BackgroundColor.nsColor(hex: spec.backgroundColorHex) {
            ctx.setFillColor(color.cgColor)
            ctx.fill(CGRect(origin: .zero, size: canvas))
            return
        }
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
        let path = CGPath(
            roundedRect: outer, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(CGColor(red: 0.16, green: 0.16, blue: 0.17, alpha: 1))
        ctx.fillPath()

        // The mirrored stream already contains the Dynamic Island / notch
        // pixels, so nothing is drawn over the video.
    }
}

/// Maps the flat canvas onto a plane rotated (yaw/pitch) about the phone's
/// center, with perspective. Also holds the reflection helpers, since the
/// reflection lies in the same plane as the phone.
struct ProjectedPlane {
    private let corners: [String: CIVector]
    /// Mirror about the phone's bottom edge.
    let flip: CGAffineTransform
    /// Mask (gray ramp) for the reflection's fade-out; nil without reflection.
    let reflectionFade: CIImage?

    init(style: SceneStyle, geo: SceneGeometry) {
        let canvas = geo.canvas
        let center = CGPoint(x: geo.outerRect.midX, y: geo.outerRect.midY)
        let distance = max(geo.outerRect.width, geo.outerRect.height) * 3.2
        let yaw = style.yaw * .pi / 180
        let pitch = style.pitch * .pi / 180

        func project(_ x: CGFloat, _ y: CGFloat) -> CIVector {
            let px = x - center.x, py = y - center.y
            // Yaw about the vertical axis: positive turns the right edge away.
            let x1 = px * cos(yaw)
            let z1 = px * sin(yaw)
            // Pitch about the horizontal axis: positive tilts the top away.
            let y2 = py * cos(pitch)
            let z2 = z1 + py * sin(pitch)
            let s = distance / (distance + z2)
            return CIVector(x: center.x + x1 * s, y: center.y + y2 * s)
        }
        corners = [
            "inputTopLeft": project(0, canvas.height),
            "inputTopRight": project(canvas.width, canvas.height),
            "inputBottomRight": project(canvas.width, 0),
            "inputBottomLeft": project(0, 0),
        ]

        let bottom = geo.outerRect.minY
        flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 2 * bottom)
        if style.reflection {
            let depth = geo.outerRect.height * SceneStyle.reflectionDepth
            reflectionFade = CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(x: 0, y: bottom),
                "inputPoint1": CIVector(x: 0, y: bottom - depth),
                "inputColor0": CIColor(red: 0.38, green: 0.38, blue: 0.38, alpha: 1),
                "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 1),
            ])?.outputImage?.cropped(to: CGRect(origin: .zero, size: canvas))
        } else {
            reflectionFade = nil
        }
    }

    func project(_ image: CIImage) -> CIImage {
        image.applyingFilter("CIPerspectiveTransform", parameters: corners)
    }
}
