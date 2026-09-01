import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var capture: CaptureController

    @AppStorage("backgroundPreset") private var backgroundPreset = 0
    @AppStorage("backgroundImagePath") private var backgroundImagePath = ""
    @AppStorage("showBezel") private var showBezel = true
    @AppStorage("bezelOverride") private var bezelOverrideRaw = "" // "" = auto
    @AppStorage("phonePadding") private var phonePadding = 48.0

    @State private var hovering = false
    @State private var showingImagePicker = false

    private var bezelOverride: BezelStyle? {
        BezelStyle(rawValue: bezelOverrideRaw)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            BackgroundView(presetID: backgroundPreset, imagePath: backgroundImagePath)

            PhoneView(showBezel: showBezel, bezelOverride: bezelOverride)
                .padding(phonePadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            controlBar
                .opacity(hovering ? 1 : 0)
                .animation(.easeInOut(duration: 0.2), value: hovering)
                .padding(.bottom, 14)
        }
        .onHover { hovering = $0 }
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

    private var controlBar: some View {
        HStack(spacing: 14) {
            deviceStatus

            Divider().frame(height: 18)

            Toggle(isOn: $showBezel) {
                Image(systemName: "iphone")
            }
            .toggleStyle(.button)
            .help("Show device frame")

            Menu {
                Picker("Frame style", selection: $bezelOverrideRaw) {
                    Text("Auto (detected)").tag("")
                    ForEach(BezelStyle.allCases) { style in
                        Text(style.rawValue).tag(style.rawValue)
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
            .help("Frame style and size")

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
    }

    private var deviceStatus: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(capture.status == .streaming ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            Text(statusText)
                .font(.callout)
                .lineLimit(1)
        }
    }

    private var statusText: String {
        switch capture.status {
        case .streaming:
            let model = PhoneModel.infer(from: capture.streamSize)
            return capture.deviceName ?? model.name
        case .accessDenied:
            return "Camera access denied"
        case .waitingForDevice:
            return "Waiting for iPhone…"
        }
    }
}
