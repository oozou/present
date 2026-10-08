import AppKit
import CoreImage
import Metal
import MetalKit
import SceneKit
import SwiftUI

/// Rotation/zoom of the 3D phone, shared by the live view and the exporters
/// so a screenshot matches whatever angle the window is showing.
final class ModelPose {
    static let shared = ModelPose()

    private let lock = NSLock()
    private var _yaw = UserDefaults.standard.double(forKey: "modelYaw")
    private var _pitch = UserDefaults.standard.double(forKey: "modelPitch")
    private var _zoom = UserDefaults.standard.object(forKey: "modelZoom") as? Double ?? 1

    /// Radians.
    var yaw: Double { get { locked { _yaw } } set { locked { _yaw = newValue } } }
    var pitch: Double { get { locked { _pitch } } set { locked { _pitch = max(-1.2, min(1.2, newValue)) } } }
    var zoom: Double { get { locked { _zoom } } set { locked { _zoom = max(0.5, min(2.5, newValue)) } } }

    func reset() { yaw = 0; pitch = 0; zoom = 1; persist() }

    func persist() {
        let d = UserDefaults.standard
        d.set(yaw, forKey: "modelYaw"); d.set(pitch, forKey: "modelPitch"); d.set(zoom, forKey: "modelZoom")
    }

    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
}

/// How to use one USDZ phone model: how it is oriented, which material is the
/// screen, and where the screen sits in that material's texture.
struct PhoneModelSpec: Identifiable {
    let id: String
    let name: String
    let file: String
    /// Rotation about Y (radians) that turns the imported model's screen to face +Z.
    let faceRotationY: Double
    let screenMaterial: String
    /// Screen region of the material's texture, in fractions (top-left origin).
    let screenUV: CGRect
    /// Whether texture U/V run against the on-screen X/Y.
    let flipU: Bool
    let flipV: Bool
    /// Black border (fraction of the screen width) drawn inside the screen
    /// texture, for models whose glass has no bezel of its own.
    var bezelInset: CGFloat = 0
    /// Corner radius of the glass as a fraction of the screen width (measured
    /// from the model's texture); the inner screen keeps it concentric.
    var cornerRadius: CGFloat = 0.12

    static let all: [PhoneModelSpec] = [
        PhoneModelSpec(
            id: "air", name: "iPhone Air", file: "iPhone_Air",
            faceRotationY: -.pi / 2, screenMaterial: "Glass___Heavy_Color",
            screenUV: CGRect(x: 8.0 / 1024, y: 8.0 / 1024, width: 446.0 / 1024, height: 977.0 / 1024),
            flipU: true, flipV: false, bezelInset: 0.005, cornerRadius: 0.1455),
        PhoneModelSpec(
            id: "pro", name: "iPhone 18 Pro Max", file: "iPhone_18_Pro_Max",
            faceRotationY: 0, screenMaterial: "COLOUR_Cherry_Screen",
            screenUV: CGRect(x: 0, y: 0, width: 1, height: 1),
            flipU: false, flipV: false),
    ]

    static func named(_ id: String) -> PhoneModelSpec {
        all.first { $0.id == id } ?? all[0]
    }

    /// The 3D model for the user's device choice ("" = follow the connected phone).
    static func resolve(override: String, device: String?) -> PhoneModelSpec {
        switch override {
        case "iPhone18,4": return named("air")
        case "iPhone18,2": return named("pro")
        default: return forDevice(device)
        }
    }

    /// The model matching a connected device's hardware identifier.
    static func forDevice(_ identifier: String?) -> PhoneModelSpec {
        // iPhone18,4 is the iPhone Air; everything else uses the Pro model.
        identifier == "iPhone18,4" ? named("air") : named("pro")
    }

    var url: URL? { Bundle.main.url(forResource: file, withExtension: "usdz", subdirectory: "Models") }
}

/// An iPhone 3D model (USDZ) with the live stream on its screen. Each
/// instance owns its own scene, so the window and the exporters never render
/// the same scene concurrently.
final class ModelPhone {
    static var isAvailable: Bool { PhoneModelSpec.all.contains { $0.url != nil } }

    private let spec: PhoneModelSpec

    let scene: SCNScene
    let cameraNode = SCNNode()
    private let pivot = SCNNode()
    private let content = SCNNode()
    private var screenMaterials: [SCNMaterial] = []
    private var modelHeight: CGFloat = 2

    private let device: MTLDevice
    private let ciContext: CIContext
    private var textureCache: CVMetalTextureCache?
    private var screenPool: CVPixelBufferPool?
    private var screenPoolSize = CGSize.zero
    private var heldTexture: CVMetalTexture?
    private var islandCache: (key: String, image: CIImage)?
    private var offscreen: SCNRenderer?
    private var targets: (size: CGSize, color: MTLTexture, msaa: MTLTexture, depth: MTLTexture)?
    private var landscape = false

    init?(spec: PhoneModelSpec) {
        guard let url = spec.url,
              let device = MTLCreateSystemDefaultDevice(),
              let loaded = try? SCNScene(url: url, options: nil)
        else { return nil }
        self.spec = spec
        self.device = device
        ciContext = CIContext(mtlDevice: device, options: [.workingColorSpace: NSNull()])
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        scene = SCNScene()

        // Re-parent the model under a normalizing node: turn its screen to face
        // the camera (+Z) and scale/center it into a 2-unit-tall box.
        for child in loaded.rootNode.childNodes { content.addChildNode(child) }
        content.eulerAngles.y = CGFloat(spec.faceRotationY)
        let (lo, hi) = content.boundingBox
        let extent = max(hi.x - lo.x, hi.y - lo.y, hi.z - lo.z)
        let s = 2.0 / extent
        content.scale = SCNVector3(s, s, s)
        content.position = SCNVector3(-(lo.x + hi.x) / 2 * s, -(lo.y + hi.y) / 2 * s, -(lo.z + hi.z) / 2 * s)
        modelHeight = (hi.y - lo.y) * s
        pivot.addChildNode(content)
        scene.rootNode.addChildNode(pivot)

        configureMaterials()
        configureLighting()

        let camera = SCNCamera()
        camera.fieldOfView = 24
        camera.projectionDirection = .vertical
        camera.zNear = 0.1
        camera.zFar = 50
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)
        applyPose()
    }

    // MARK: Scene setup

    private func configureMaterials() {
        content.enumerateChildNodes { node, _ in
            for material in node.geometry?.materials ?? [] {
                material.isDoubleSided = false
                if material.name == spec.screenMaterial {
                    // The screen: its texture becomes the live stream, drawn
                    // unlit so colors come through untouched.
                    material.lightingModel = .constant
                    material.emission.contents = nil
                    material.normal.contents = nil
                    material.reflective.contents = nil
                    material.specular.contents = nil
                    material.transparent.contents = nil
                    material.transparency = 1
                    material.blendMode = .replace
                    material.diffuse.contents = NSColor.black
                    material.diffuse.wrapS = .clamp
                    material.diffuse.wrapT = .clamp
                    material.diffuse.minificationFilter = .linear
                    material.diffuse.magnificationFilter = .linear
                    material.diffuse.mipFilter = .none
                    material.diffuse.contentsTransform = screenTransform()
                    self.screenMaterials.append(material)
                }
            }
        }
    }

    /// Maps the screen's UVs onto a full-frame video texture.
    private func screenTransform() -> SCNMatrix4 {
        let r = spec.screenUV
        // Region fractions are top-left based; flip decides which way each axis runs.
        let sx = (spec.flipU ? -1 : 1) / r.width
        let tx = spec.flipU ? 1 + r.minX / r.width : -r.minX / r.width
        let sy = (spec.flipV ? -1 : 1) / r.height
        let ty = spec.flipV ? 1 + r.minY / r.height : -r.minY / r.height
        var m = SCNMatrix4Identity
        m.m11 = sx; m.m41 = tx
        m.m22 = sy; m.m42 = ty
        return m
    }

    private func configureLighting() {
        scene.background.contents = NSColor.clear
        scene.lightingEnvironment.contents = Self.studioEnvironment()
        scene.lightingEnvironment.intensity = 2.0
    }

    /// A dark product-shot studio: near-black room ringed with large softboxes
    /// across the horizon, so the polished metal rails reflect broad bright
    /// bands from any angle (like Quick Look's studio), and glass sees crisp
    /// strips.
    private static func studioEnvironment() -> NSImage {
        let size = NSSize(width: 2048, height: 1024)
        return NSImage(size: size, flipped: false) { rect in
            NSGradient(colorsAndLocations:
                (NSColor(white: 0.03, alpha: 1), 0.0),
                (NSColor(white: 0.10, alpha: 1), 0.40),
                (NSColor(white: 0.22, alpha: 1), 0.55),
                (NSColor(white: 0.55, alpha: 1), 1.0)
            )?.draw(in: rect, angle: 90)

            func box(_ r: NSRect, _ white: CGFloat, radius: CGFloat = 14) {
                NSColor(white: white, alpha: 1).setFill()
                NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
            }
            // Horizon softboxes (what side rails mostly reflect).
            for (index, x) in [150.0, 660.0, 1170.0, 1680.0].enumerated() {
                box(NSRect(x: x, y: 360, width: 300 - CGFloat(index % 2) * 90, height: 330), 1.0)
            }
            // Thin vertical strips between them for crisp edge glints.
            for x in [500.0, 1010.0, 1520.0, 1960.0] {
                box(NSRect(x: x, y: 330, width: 40, height: 400), 0.9, radius: 6)
            }
            // Overhead bars.
            box(NSRect(x: 700, y: 840, width: 640, height: 80), 1.0)
            box(NSRect(x: 200, y: 760, width: 360, height: 70), 0.9)
            return true
        }
    }

    // MARK: Pose

    /// Applies the shared rotation/zoom and keeps the camera framing the phone.
    func applyPose() {
        let pose = ModelPose.shared
        let roll = landscape ? -CGFloat.pi / 2 : 0
        pivot.eulerAngles = SCNVector3(CGFloat(pose.pitch), CGFloat(pose.yaw), roll)
        let fov = CGFloat(cameraNode.camera?.fieldOfView ?? 24) * .pi / 180
        // Fit the phone's height (with margin) at zoom 1.
        let distance = (modelHeight / 2) * 1.18 / tan(fov / 2) / CGFloat(pose.zoom)
        cameraNode.position = SCNVector3(0, 0, distance)
    }

    // MARK: Screen texture

    /// Draws `frame` (plus the Dynamic Island fill when requested) into a
    /// pooled GPU buffer and points the screen material at it.
    func updateScreen(frame: CVPixelBuffer, overlayIsland: Bool) {
        let w = CGFloat(CVPixelBufferGetWidth(frame)), h = CGFloat(CVPixelBufferGetHeight(frame))
        var image = CIImage(cvPixelBuffer: frame)
        if overlayIsland, let island = islandImage(streamSize: CGSize(width: w, height: h)) {
            image = island.composited(over: image)
        }
        let isLandscape = w > h
        if isLandscape { image = image.oriented(.right) }   // portrait for the portrait-UV screen
        let size = isLandscape ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
        if spec.bezelInset > 0 { image = withBezel(image, size: size) }
        if isLandscape != landscape {
            landscape = isLandscape
            applyPose()
        }

        if screenPool == nil || screenPoolSize != size {
            screenPoolSize = size
            CVPixelBufferPoolCreate(nil, nil, [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ] as CFDictionary, &screenPool)
        }
        guard let screenPool, let textureCache else { return }
        var target: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, screenPool, &target)
        guard let target else { return }
        ciContext.render(image, to: target)

        var cvTexture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, target, nil, .bgra8Unorm_srgb,
            Int(size.width), Int(size.height), 0, &cvTexture)
        guard let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) else { return }
        heldTexture = cvTexture   // keep alive until the next frame replaces it

        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        for material in screenMaterials { material.diffuse.contents = texture }
        SCNTransaction.commit()
    }

    private var bezelMaskCache: (size: CGSize, image: CIImage)?

    /// Shrinks the picture into a rounded inner screen on black, so the glass
    /// gets the thin black bezel a real iPhone has.
    private func withBezel(_ image: CIImage, size: CGSize) -> CIImage {
        let d = (size.width * spec.bezelInset).rounded()
        let inner = CGRect(x: d, y: d, width: size.width - 2 * d, height: size.height - 2 * d)

        if bezelMaskCache?.size != size {
            let radius = max(0, size.width * spec.cornerRadius - d)
            if let ctx = CGContext(
                data: nil, width: Int(size.width), height: Int(size.height),
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.setFillColor(CGColor(gray: 0, alpha: 1))
                ctx.fill(CGRect(origin: .zero, size: size))
                ctx.setFillColor(CGColor(gray: 1, alpha: 1))
                ctx.addPath(CGPath(roundedRect: inner, cornerWidth: radius, cornerHeight: radius, transform: nil))
                ctx.fillPath()
                if let cg = ctx.makeImage() { bezelMaskCache = (size, CIImage(cgImage: cg)) }
            }
        }
        guard let mask = bezelMaskCache?.image,
              let blend = CIFilter(name: "CIBlendWithMask")
        else { return image }

        let fitted = image
            .transformed(by: CGAffineTransform(scaleX: inner.width / size.width, y: inner.height / size.height))
            .transformed(by: CGAffineTransform(translationX: inner.minX, y: inner.minY))
        blend.setValue(fitted, forKey: kCIInputImageKey)
        blend.setValue(CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size)), forKey: kCIInputBackgroundImageKey)
        blend.setValue(mask, forKey: kCIInputMaskImageKey)
        return blend.outputImage ?? image
    }

    /// Black pill in stream pixel coordinates (top-left origin → CI bottom-left).
    private func islandImage(streamSize: CGSize) -> CIImage? {
        guard let rect = DynamicIsland.rect(streamSize: streamSize) else { return nil }
        let key = "\(streamSize)|\(rect)"
        if let cache = islandCache, cache.key == key { return cache.image }
        guard let ctx = CGContext(
            data: nil, width: Int(streamSize.width), height: Int(streamSize.height),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let r = CGRect(x: rect.minX, y: streamSize.height - rect.minY - rect.height,
                       width: rect.width, height: rect.height)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fillPath()
        guard let cg = ctx.makeImage() else { return nil }
        let image = CIImage(cgImage: cg)
        islandCache = (key, image)
        return image
    }

    // MARK: Offscreen render (exports)

    /// Renders the phone with `frame` on its screen, onto a transparent canvas.
    func render(frame: CVPixelBuffer, overlayIsland: Bool, canvas: CGSize) -> CIImage? {
        updateScreen(frame: frame, overlayIsland: overlayIsland)
        applyPose()
        // Keep the exported phone at the same on-canvas size as in the window,
        // whatever the canvas aspect: fit by height.
        guard let targets = ensureTargets(size: canvas), let queue = device.makeCommandQueue(),
              let commandBuffer = queue.makeCommandBuffer()
        else { return nil }

        if offscreen == nil {
            offscreen = SCNRenderer(device: device, options: nil)
            offscreen?.scene = scene
            offscreen?.pointOfView = cameraNode
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = targets.msaa
        pass.colorAttachments[0].resolveTexture = targets.color
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .multisampleResolve
        pass.depthAttachment.texture = targets.depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1
        pass.depthAttachment.storeAction = .dontCare
        pass.stencilAttachment.texture = targets.depth
        pass.stencilAttachment.loadAction = .clear
        pass.stencilAttachment.storeAction = .dontCare

        offscreen?.render(
            atTime: CACurrentMediaTime(),
            viewport: CGRect(origin: .zero, size: canvas),
            commandBuffer: commandBuffer, passDescriptor: pass)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // Metal textures are top-left origin; CoreImage wants bottom-left.
        guard let raw = targets.color.makeTextureView(pixelFormat: .bgra8Unorm) else { return nil }
        return CIImage(mtlTexture: raw, options: [.colorSpace: NSNull()])?
            .oriented(.downMirrored)
    }

    private func ensureTargets(size: CGSize) -> (size: CGSize, color: MTLTexture, msaa: MTLTexture, depth: MTLTexture)? {
        if let targets, targets.size == size { return targets }
        let w = Int(size.width), h = Int(size.height)
        // sRGB targets so SceneKit's output is gamma-encoded exactly like the
        // window; CoreImage then reads the raw bytes through a plain view.
        let color = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: w, height: h, mipmapped: false)
        color.usage = [.renderTarget, .shaderRead, .pixelFormatView]
        color.storageMode = .shared

        let msaa = MTLTextureDescriptor()
        msaa.textureType = .type2DMultisample
        msaa.pixelFormat = .bgra8Unorm_srgb
        msaa.width = w; msaa.height = h; msaa.sampleCount = 4
        msaa.usage = .renderTarget
        msaa.storageMode = .private

        let depth = MTLTextureDescriptor()
        depth.textureType = .type2DMultisample
        depth.pixelFormat = .depth32Float_stencil8
        depth.width = w; depth.height = h; depth.sampleCount = 4
        depth.usage = .renderTarget
        depth.storageMode = .private

        guard let c = device.makeTexture(descriptor: color),
              let m = device.makeTexture(descriptor: msaa),
              let d = device.makeTexture(descriptor: depth)
        else { return nil }
        targets = (size, c, m, d)
        return targets
    }
}

// MARK: - Live view

/// The window's 3D phone: drag to rotate, scroll or pinch to zoom,
/// double-click to reset.
struct ModelPhoneView: NSViewRepresentable {
    let capture: CaptureController
    let spec: PhoneModelSpec

    func makeNSView(context: Context) -> ModelSCNView {
        ModelSCNView(capture: capture, spec: spec)
    }

    func updateNSView(_ nsView: ModelSCNView, context: Context) {}
}

/// Draws the model with SceneKit's offscreen renderer into our own sRGB
/// MTKView. (SCNView's built-in presentation reinterprets colors for the
/// display and washed the stream out; this matches the exporters exactly.)
final class ModelSCNView: MTKView, MTKViewDelegate {
    private let model: ModelPhone?
    private let capture: CaptureController
    private let renderer: SCNRenderer?
    private let queue: MTLCommandQueue?
    private var lastFrame: CVPixelBuffer?
    private var lastOverlay = false

    init(capture: CaptureController, spec: PhoneModelSpec) {
        self.capture = capture
        let model = ModelPhone(spec: spec)
        self.model = model
        let device = MTLCreateSystemDefaultDevice()
        queue = device?.makeCommandQueue()
        if let model, let device {
            let r = SCNRenderer(device: device, options: nil)
            r.scene = model.scene
            r.pointOfView = model.cameraNode
            renderer = r
        } else {
            renderer = nil
        }
        super.init(frame: .zero, device: device)
        colorPixelFormat = .bgra8Unorm_srgb
        depthStencilPixelFormat = .depth32Float_stencil8
        sampleCount = 4
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        preferredFramesPerSecond = 60
        framebufferOnly = true
        delegate = self
        if let metal = layer as? CAMetalLayer {
            metal.isOpaque = false
            // The rest of the window (and the exporters) treat pixel values as
            // display-native; an untagged layer is color-managed as sRGB and
            // comes out paler next to them. Tag it as the display's space.
            metal.colorspace = window?.colorSpace?.cgColorSpace ?? CGColorSpace(name: CGColorSpace.displayP3)
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    /// Dragging the phone must not drag the window.
    override var mouseDownCanMoveWindow: Bool { false }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let model, let renderer, let queue,
              let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = queue.makeCommandBuffer()
        else { return }

        model.applyPose()
        if let frame = capture.latestFrame {
            let overlay = DynamicIsland.mode != "off" && capture.islandOverlayNeededNow
            if frame !== lastFrame || overlay != lastOverlay {
                lastFrame = frame
                lastOverlay = overlay
                model.updateScreen(frame: frame, overlayIsland: overlay)
            }
        }

        renderer.render(
            atTime: CACurrentMediaTime(),
            viewport: CGRect(origin: .zero, size: view.drawableSize),
            commandBuffer: commandBuffer, passDescriptor: pass)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    override func mouseDragged(with event: NSEvent) {
        let pose = ModelPose.shared
        pose.yaw += Double(event.deltaX) * 0.01
        pose.pitch += Double(event.deltaY) * 0.01
    }

    override func mouseUp(with event: NSEvent) {
        if event.clickCount == 2 { ModelPose.shared.reset() } else { ModelPose.shared.persist() }
    }

    override func scrollWheel(with event: NSEvent) {
        ModelPose.shared.zoom *= 1 + Double(event.scrollingDeltaY) * 0.01
        ModelPose.shared.persist()
    }

    override func magnify(with event: NSEvent) {
        ModelPose.shared.zoom *= 1 + Double(event.magnification)
        ModelPose.shared.persist()
    }
}
