import AVFoundation
import AppKit

/// Debug aid: launching with `PRESENT_TEST_PATTERN=1` feeds a synthetic
/// portrait stream through the normal pipeline, so the preview, effects,
/// exports and virtual camera can be exercised without a phone attached.
final class TestPatternSource {
    let size: CGSize
    private let queue = DispatchQueue(label: "de.consti.present.testpattern")
    private var timer: DispatchSourceTimer?
    private var pool: CVPixelBufferPool?
    private var frameIndex = 0

    init(size: CGSize) {
        self.size = size
        CVPixelBufferPoolCreate(nil, nil, [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ] as CFDictionary, &pool)
    }

    func start(_ handler: @escaping (CMSampleBuffer) -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16))
        timer.setEventHandler { [weak self] in
            guard let self, let sample = self.nextFrame() else { return }
            handler(sample)
        }
        self.timer = timer
        timer.resume()
    }

    func stop() { timer?.cancel(); timer = nil }

    private func nextFrame() -> CMSampleBuffer? {
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer),
           let ctx = CGContext(
            data: base, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue) {
            draw(in: ctx)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format)
        guard let format else { return nil }
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: buffer, formatDescription: format,
            sampleTiming: &timing, sampleBufferOut: &sample)
        frameIndex += 1
        return sample
    }

    private func draw(in ctx: CGContext) {
        let w = size.width, h = size.height
        let colors = [
            CGColor(red: 0.0, green: 0.75, blue: 0.9, alpha: 1),
            CGColor(red: 0.12, green: 0.3, blue: 0.9, alpha: 1),
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: nil) {
            ctx.drawLinearGradient(
                gradient, start: CGPoint(x: 0, y: h), end: .zero, options: [])
        }

        // Moving circle: easy to judge smoothness and latency by eye.
        let t = Double(frameIndex) / 60
        let cx = w / 2 + sin(t * 2) * w * 0.28
        let cy = h / 2 + cos(t * 1.3) * h * 0.2
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: cx - 120, y: cy - 120, width: 240, height: 240))

        // Frame counter.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        ("\(frameIndex)" as NSString).draw(
            at: CGPoint(x: 80, y: 80),
            withAttributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 90, weight: .bold),
                .foregroundColor: NSColor.white,
            ])
        NSGraphicsContext.restoreGraphicsState()
    }
}
