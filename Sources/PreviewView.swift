import SwiftUI
import AVFoundation

/// Hosts an AVCaptureVideoPreviewLayer — the lowest-latency path for showing
/// a capture stream (frames go straight from the session to the compositor).
struct PreviewView: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewNSView {
        PreviewNSView(session: session)
    }

    func updateNSView(_ nsView: PreviewNSView, context: Context) {}
}

final class PreviewNSView: NSView {
    init(session: AVCaptureSession) {
        super.init(frame: .zero)
        wantsLayer = true
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.backgroundColor = NSColor.black.cgColor
        layer = previewLayer
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
