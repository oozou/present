import SwiftUI
import AVFoundation

/// Hosts the AVSampleBufferDisplayLayer that CaptureController feeds with
/// retimed, display-immediately frames (lower latency than
/// AVCaptureVideoPreviewLayer for iPhone screen capture).
struct PreviewView: NSViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    func makeNSView(context: Context) -> PreviewNSView {
        PreviewNSView(displayLayer: layer)
    }

    func updateNSView(_ nsView: PreviewNSView, context: Context) {}
}

final class PreviewNSView: NSView {
    private let displayLayer: AVSampleBufferDisplayLayer

    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        displayLayer.videoGravity = .resizeAspectFill
        displayLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(displayLayer)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
    }

    /// Without this the layer renders at 1x on Retina displays and the
    /// stream looks soft.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let scale = window?.backingScaleFactor {
            layer?.contentsScale = scale
            displayLayer.contentsScale = scale
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
