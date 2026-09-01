import SwiftUI

@main
struct PresentApp: App {
    @StateObject private var capture = CaptureController()

    var body: some Scene {
        Window("Present", id: "main") {
            ContentView()
                .environmentObject(capture)
                .frame(minWidth: 360, minHeight: 560)
                .background(WindowConfigurator())
        }
        .windowStyle(.hiddenTitleBar)
    }
}

/// Makes the borderless window draggable by its background.
private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.isMovableByWindowBackground = true
            window.titlebarAppearsTransparent = true
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
