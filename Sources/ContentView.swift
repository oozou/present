import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var capture: CaptureController

    @AppStorage("backgroundPreset") private var backgroundPreset = 0
    @AppStorage("backgroundImagePath") private var backgroundImagePath = ""
    @AppStorage("showBezel") private var showBezel = true
    @AppStorage("frameMode") private var frameMode = "photoreal" // photoreal | drawn
    @AppStorage("modelOverride") private var modelOverride = "" // "" = auto
    @AppStorage("phonePadding") private var phonePadding = 48.0

    @State private var barVisible = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                BackgroundView(presetID: backgroundPreset, imagePath: backgroundImagePath)

                PhoneView(
                    showBezel: showBezel,
                    useChrome: frameMode == "photoreal",
                    modelOverride: modelOverride)
                    .padding(phonePadding)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(spacing: 8) {
                    ToastView(media: capture.media)
                    ControlBar(
                        media: capture.media,
                        backgroundPreset: $backgroundPreset,
                        backgroundImagePath: $backgroundImagePath,
                        showBezel: $showBezel,
                        frameMode: $frameMode,
                        modelOverride: $modelOverride,
                        phonePadding: $phonePadding,
                        makeSpec: sceneSpec)
                        .opacity(barVisible ? 1 : 0)
                        .offset(y: barVisible ? 0 : 24)
                        .allowsHitTesting(barVisible)
                }
                .padding(.bottom, 14)
            }
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

    private func sceneSpec() -> SceneSpec? {
        guard let streamSize = capture.streamSize else { return nil }
        let inferred = PhoneModel.infer(from: streamSize)
        let identifier = modelOverride.isEmpty
            ? (capture.modelIdentifier ?? inferred.identifier)
            : modelOverride
        return SceneSpec(
            streamSize: streamSize,
            chrome: showBezel && frameMode == "photoreal"
                ? DeviceChrome.load(modelIdentifier: identifier) : nil,
            fallbackStyle: inferred.bezel,
            showBezel: showBezel,
            backgroundPresetID: backgroundPreset,
            backgroundImagePath: backgroundImagePath)
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

    @Binding var backgroundPreset: Int
    @Binding var backgroundImagePath: String
    @Binding var showBezel: Bool
    @Binding var frameMode: String
    @Binding var modelOverride: String
    @Binding var phonePadding: Double
    let makeSpec: () -> SceneSpec?

    @State private var showingImagePicker = false

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
                Picker("Frame style", selection: $frameMode) {
                    Text("Photoreal (Simulator art)").tag("photoreal")
                    Text("Stylized (drawn)").tag("drawn")
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
            }
            .buttonStyle(.plain)
            .disabled(!capture.isStreaming)
            .keyboardShortcut("r", modifiers: .command)
            .help(media.isRecording ? "Stop recording (⌘R)" : "Record to Movies (⌘R)")

            Divider().frame(height: 18)

            ForEach(BackgroundPreset.all) { preset in
                Button {
                    backgroundPreset = preset.id
                } label: {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: preset.colors,
                                startPoint: .topLeading, endPoint: .bottomTrailing))
                        .overlay(
                            Circle().strokeBorder(
                                backgroundPreset == preset.id ? Color.white : Color.white.opacity(0.25),
                                lineWidth: backgroundPreset == preset.id ? 2 : 1))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help(preset.name)
            }

            Button {
                showingImagePicker = true
            } label: {
                Image(systemName: "photo")
                    .overlay(alignment: .bottomTrailing) {
                        if backgroundPreset == -1 {
                            Circle().fill(.white).frame(width: 5, height: 5).offset(x: 3, y: 3)
                        }
                    }
            }
            .buttonStyle(.plain)
            .help("Use an image as background")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        .fileImporter(
            isPresented: $showingImagePicker,
            allowedContentTypes: [.image]
        ) { result in
            if case .success(let url) = result {
                backgroundImagePath = url.path
                backgroundPreset = -1
            }
        }
    }

    private func takeScreenshot() {
        guard let spec = makeSpec(), let frame = capture.latestFrame else { return }
        media.saveScreenshot(spec: spec, frame: frame)
    }

    private func toggleRecording() {
        if media.isRecording {
            media.stopRecording()
        } else if let spec = makeSpec() {
            media.startRecording(spec: spec)
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
