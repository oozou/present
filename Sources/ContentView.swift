import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var capture: CaptureController
    @Environment(\.openSettings) private var openSettings

    @AppStorage("backgroundPreset") private var backgroundPreset = 0
    @AppStorage("backgroundImagePath") private var backgroundImagePath = ""
    @AppStorage("backgroundColorHex") private var backgroundColorHex = ""
    @AppStorage("showBezel") private var showBezel = true
    @AppStorage("deviceFinish") private var deviceFinish = DeviceFinish.original.id
    @AppStorage("phoneShadow") private var phoneShadow = true
    @AppStorage("phoneReflection") private var phoneReflection = false
    @AppStorage("phoneModel3D") private var phoneModel3D = false
    @AppStorage("modelOverride") private var modelOverride = "" // "" = follow the connected phone
    @AppStorage("phonePadding") private var phonePadding = 48.0

    private var style: SceneStyle {
        SceneStyle(
            shadow: phoneShadow, reflection: phoneReflection, model3D: phoneModel3D,
            modelID: PhoneModelSpec.resolve(
                override: modelOverride, device: capture.modelIdentifier).id)
    }

    @State private var barVisible = false
    @State private var flash = 0.0

    // Live island calibration (⌥-arrows); shared with detection and exports.
    @AppStorage("islandY") private var islandY = 41.0
    @AppStorage("islandHeight") private var islandHeight = 111.0
    @AppStorage("islandWidth") private var islandWidth = 378.0
    @State private var calibrationReadout: String?
    @State private var readoutFadeTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                BackgroundView(
                    presetID: backgroundPreset, imagePath: backgroundImagePath,
                    colorHex: backgroundColorHex)

                PhoneView(
                    showBezel: showBezel,
                    useChrome: true,
                    modelOverride: modelOverride,
                    finish: deviceFinish,
                    style: style)
                    .padding(phonePadding)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Shutter flash for screenshots / recording start.
                Color.white
                    .opacity(flash)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                VStack(spacing: 8) {
                    ToastView(media: capture.media)
                    ControlBar(
                        media: capture.media,
                        showBezel: $showBezel,
                        modelOverride: $modelOverride,
                        phonePadding: $phonePadding,
                        makeSpec: sceneSpec,
                        triggerFlash: triggerFlash)
                        .opacity(barVisible ? 1 : 0)
                        .offset(y: barVisible ? 0 : 24)
                        .allowsHitTesting(barVisible)
                }
                .padding(.bottom, 14)
            }
            .overlay(alignment: .top) {
                if let calibrationReadout {
                    Text(calibrationReadout)
                        .font(.callout.monospaced())
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 16)
                        .transition(.opacity)
                }
            }
            .background(calibrationShortcuts)
            .task { await debugExportIfRequested() }
            // Dock-style reveal: only when the cursor is near the bottom edge.
            .onContinuousHover { phase in
                let visible: Bool
                switch phase {
                case .active(let point):
                    visible = point.y > geo.size.height - 70
                case .ended:
                    visible = false
                }
                if visible != barVisible {
                    withAnimation(.easeOut(duration: 0.18)) { barVisible = visible }
                }
            }
        }
    }

    /// ⌥↑/⌥↓ move the island, ⌥⇧↑/⌥⇧↓ change its height, ⌥←/⌥→ its width.
    private var calibrationShortcuts: some View {
        Group {
            Button("") { adjustIsland(dy: -1) }
                .keyboardShortcut(.upArrow, modifiers: .option)
            Button("") { adjustIsland(dy: 1) }
                .keyboardShortcut(.downArrow, modifiers: .option)
            Button("") { adjustIsland(dh: -1) }
                .keyboardShortcut(.upArrow, modifiers: [.option, .shift])
            Button("") { adjustIsland(dh: 1) }
                .keyboardShortcut(.downArrow, modifiers: [.option, .shift])
            Button("") { adjustIsland(dw: -2) }
                .keyboardShortcut(.leftArrow, modifiers: .option)
            Button("") { adjustIsland(dw: 2) }
                .keyboardShortcut(.rightArrow, modifiers: .option)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
    }

    private func adjustIsland(dy: Double = 0, dh: Double = 0, dw: Double = 0) {
        islandY += dy
        islandHeight = max(10, islandHeight + dh)
        islandWidth = max(20, islandWidth + dw)
        withAnimation(.easeIn(duration: 0.1)) {
            calibrationReadout =
                "island  y \(Int(islandY)) · h \(Int(islandHeight)) · w \(Int(islandWidth))"
        }
        readoutFadeTask?.cancel()
        readoutFadeTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { calibrationReadout = nil }
        }
    }

    /// Debug: `PRESENT_TEST_EXPORT=/path.png` saves one composed screenshot a
    /// few seconds after launch (used with PRESENT_TEST_PATTERN) and quits.
    private func debugExportIfRequested() async {
        if ProcessInfo.processInfo.environment["PRESENT_OPEN_SETTINGS"] != nil {
            try? await Task.sleep(for: .seconds(1))
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        guard let path = ProcessInfo.processInfo.environment["PRESENT_TEST_EXPORT"] else { return }
        try? await Task.sleep(for: .seconds(3))
        if let spec = sceneSpec(), let frame = capture.latestFrame {
            capture.media.saveScreenshot(
                spec: spec, frame: frame, overlayIsland: capture.islandOverlayNeededNow,
                to: URL(fileURLWithPath: path))
        }
        try? await Task.sleep(for: .seconds(1))
        NSApp.terminate(nil)
    }

    private func triggerFlash() {
        flash = 0.85
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.45)) { flash = 0 }
        }
    }

    private func sceneSpec() -> SceneSpec? {
        guard let streamSize = capture.streamSize else { return nil }
        let inferred = PhoneModel.infer(from: streamSize)
        let identifier = modelOverride.isEmpty
            ? (capture.modelIdentifier ?? inferred.identifier)
            : modelOverride
        return SceneSpec(
            streamSize: streamSize,
            chrome: showBezel
                ? DeviceChrome.load(modelIdentifier: identifier, finish: deviceFinish) : nil,
            fallbackStyle: inferred.bezel,
            showBezel: showBezel,
            backgroundPresetID: backgroundPreset,
            backgroundImagePath: backgroundImagePath,
            backgroundColorHex: backgroundColorHex,
            style: style)
    }
}

private struct ToastView: View {
    @ObservedObject var media: MediaExporter

    var body: some View {
        if let toast = media.toast {
            Text(toast)
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .transition(.opacity)
        }
    }
}

private struct ControlBar: View {
    @EnvironmentObject private var capture: CaptureController
    @ObservedObject var media: MediaExporter

    @Binding var showBezel: Bool
    @Binding var modelOverride: String
    @Binding var phonePadding: Double
    let makeSpec: () -> SceneSpec?
    let triggerFlash: () -> Void

    @AppStorage("islandMode") private var islandMode = "auto"

    var body: some View {
        HStack(spacing: 14) {
            deviceStatus

            Divider().frame(height: 18)

            Toggle(isOn: $showBezel) {
                Image(systemName: "iphone")
            }
            .toggleStyle(.button)
            .help("Show device frame")

            Menu {
                Picker("Dynamic Island", selection: $islandMode) {
                    Text("Fill when idle").tag("auto")
                    Text("Always (calibrate)").tag("always")
                    Text("Off").tag("off")
                }
                .pickerStyle(.inline)

                Divider()

                Picker("Device", selection: $modelOverride) {
                    Text("Auto (detected)").tag("")
                    ForEach(PhoneModel.overrideChoices, id: \.identifier) { choice in
                        Text(choice.name).tag(choice.identifier)
                    }
                }
                .pickerStyle(.inline)

                Divider()

                Picker("Phone size", selection: $phonePadding) {
                    Text("Large").tag(24.0)
                    Text("Medium").tag(48.0)
                    Text("Small").tag(96.0)
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Device model and size")

            Divider().frame(height: 18)

            Button(action: takeScreenshot) {
                Image(systemName: "camera")
            }
            .buttonStyle(.plain)
            .disabled(!capture.isStreaming)
            .keyboardShortcut("s", modifiers: .command)
            .help("Save a screenshot to Pictures (⌘S)")

            Button(action: toggleRecording) {
                Image(systemName: media.isRecording ? "stop.circle.fill" : "record.circle")
                    .foregroundStyle(media.isRecording ? Color.red : Color.primary)
                    .symbolEffect(.pulse, options: .repeating, isActive: media.isRecording)
            }
            .buttonStyle(.plain)
            .disabled(!capture.isStreaming)
            .keyboardShortcut("r", modifiers: .command)
            .help(media.isRecording ? "Stop recording (⌘R)" : "Record to Movies (⌘R)")

            Divider().frame(height: 18)

            SettingsLink {
                Image(systemName: "photo.on.rectangle.angled")
            }
            .buttonStyle(.plain)
            .help("Backgrounds and settings (⌘,)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
    }

    private func takeScreenshot() {
        guard let spec = makeSpec(), let frame = capture.latestFrame else { return }
        triggerFlash()
        media.saveScreenshot(
            spec: spec, frame: frame,
            overlayIsland: DynamicIsland.mode != "off" && capture.islandOverlayNeededNow)
    }

    private func toggleRecording() {
        if media.isRecording {
            media.stopRecording()
        } else if let spec = makeSpec() {
            triggerFlash()
            let capture = self.capture
            media.startRecording(spec: spec) {
                DynamicIsland.mode != "off" && capture.islandOverlayNeededNow
            }
        }
    }

    private var deviceStatus: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(capture.isStreaming ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            Text(statusText)
                .font(.callout)
                .lineLimit(1)
        }
    }

    private var statusText: String {
        switch capture.status {
        case .streaming:
            let name = capture.deviceName ?? "iPhone"
            if let model = capture.modelIdentifier {
                return "\(name) · \(model)"
            }
            return "\(name) · \(PhoneModel.infer(from: capture.streamSize).name)"
        case .accessDenied:
            return "Camera access denied"
        case .error:
            return "Stream error"
        case .waitingForDevice:
            return "Waiting for iPhone…"
        }
    }
}
