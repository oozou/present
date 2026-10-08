import SwiftUI
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// User-uploaded background images. Files are copied into Application Support
/// so they keep working if the original is moved or deleted.
@MainActor
final class UserBackgrounds: ObservableObject {
    static let shared = UserBackgrounds()

    @Published private(set) var items: [URL] = []
    private let folder: URL

    private init() {
        folder = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Present/Backgrounds", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        reload()
    }

    private func reload() {
        let keys: [URLResourceKey] = [.creationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys,
            options: .skipsHiddenFiles)) ?? []
        items = urls.sorted {
            let a = (try? $0.resourceValues(forKeys: Set(keys)).creationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: Set(keys)).creationDate) ?? .distantPast
            return a < b
        }
    }

    /// Copies `source` into the library and returns the stored URL.
    func add(_ source: URL) -> URL? {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        let destination = folder
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(source.pathExtension)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            Log.write("background import failed: \(error.localizedDescription)")
            return nil
        }
        reload()
        return destination
    }

    func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        reload()
    }
}

// MARK: - Settings window

struct SettingsView: View {
    var body: some View {
        TabView {
            DevicesSettings()
                .tabItem { Label("Devices", systemImage: "iphone") }
            StyleSettings()
                .tabItem { Label("Style", systemImage: "cube.transparent") }
            BackgroundSettings()
                .tabItem { Label("Background", systemImage: "photo.on.rectangle.angled") }
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 600)
    }
}

/// "Label:" on the left (right-aligned), controls on the right.
private struct SettingsRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label.isEmpty ? "" : "\(label):")
                .frame(width: 100, alignment: .trailing)
            content()
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Devices

private struct DevicesSettings: View {
    @AppStorage("showBezel") private var showBezel = true
    @AppStorage("phoneModel3D") private var model3D = false
    @AppStorage("modelOverride") private var modelOverride = ""
    @AppStorage("phonePadding") private var phonePadding = 48.0
    @AppStorage("islandMode") private var islandMode = "auto"
    @AppStorage("deviceFinish") private var deviceFinish = DeviceFinish.original.id

    private func finishColor(_ finish: DeviceFinish) -> Color {
        guard let rgb = finish.rgb else { return Color(white: 0.22) }
        return Color(red: rgb.0, green: rgb.1, blue: rgb.2)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsRow(label: "Device frame") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Show frame around the screen", isOn: $showBezel)
                        .disabled(model3D)
                }
            }

            SettingsRow(label: "Device") {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("", selection: $modelOverride) {
                        Text("Auto (detected)").tag("")
                        ForEach(PhoneModel.overrideChoices, id: \.identifier) { choice in
                            Text(choice.name).tag(choice.identifier)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    caption("Auto follows the connected iPhone. Also picks the 3D model.")
                }
            }

            SettingsRow(label: "Finish") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        ForEach(DeviceFinish.all) { finish in
                            Button {
                                deviceFinish = finish.id
                            } label: {
                                Circle()
                                    .fill(finishColor(finish))
                                    .frame(width: 26, height: 26)
                                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 1))
                                    .overlay(
                                        Circle()
                                            .inset(by: -3)
                                            .strokeBorder(
                                                Color.accentColor,
                                                lineWidth: deviceFinish == finish.id ? 2.5 : 0))
                            }
                            .buttonStyle(.plain)
                            .help(finish.name)
                        }
                    }
                    caption("\(DeviceFinish.named(deviceFinish).name) · recolors the frame artwork (frame artwork only).")
                }
            }
            .disabled(!showBezel || model3D)

            SettingsRow(label: "Phone size") {
                Picker("", selection: $phonePadding) {
                    Text("Large").tag(24.0)
                    Text("Medium").tag(48.0)
                    Text("Small").tag(96.0)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 220)
            }

            SettingsRow(label: "Dynamic Island") {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("", selection: $islandMode) {
                        Text("Fill when idle").tag("auto")
                        Text("Always (calibrate)").tag("always")
                        Text("Off").tag("off")
                    }
                    .labelsHidden()
                    .fixedSize()
                    caption("Idle mirror streams omit the island, so a black pill is drawn in. Calibrate with ⌥-arrows.")
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Style

private struct StyleSettings: View {
    @AppStorage("phoneShadow") private var shadow = true
    @AppStorage("phoneReflection") private var reflection = false
    @AppStorage("phoneModel3D") private var model3D = false
    // The pose lives in ModelPose (the window edits it by dragging); this
    // tick just refreshes the sliders while the window is open.
    @State private var tick = 0

    private let pose = ModelPose.shared
    private let degrees = 180 / Double.pi

    var body: some View {
        let _ = tick
        VStack(alignment: .leading, spacing: 18) {
            SettingsRow(label: "Phone") {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("", selection: $model3D) {
                        Text("Frame artwork").tag(false)
                        Text("3D model").tag(true)
                    }
                    .labelsHidden()
                    .pickerStyle(.radioGroup)
                    .disabled(!ModelPhone.isAvailable)
                    Text("Choose the phone under Devices. With the 3D model you can also drag it in the window to rotate, scroll or pinch to zoom, and double-click to reset.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            SettingsRow(label: "Angle") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        ForEach(SceneStyle.tiltPresets, id: \.name) { preset in
                            Button(preset.name) {
                                pose.yaw = preset.yaw / degrees
                                pose.pitch = preset.pitch / degrees
                                pose.persist()
                                tick += 1
                            }
                            .buttonStyle(.bordered)
                            .tint(isCurrent(preset) ? .accentColor : nil)
                        }
                    }
                    slider("Turn", value: Binding(
                        get: { pose.yaw * degrees },
                        set: { pose.yaw = $0 / degrees; pose.persist(); tick += 1 }
                    ), range: -75...75)
                    slider("Lean", value: Binding(
                        get: { pose.pitch * degrees },
                        set: { pose.pitch = $0 / degrees; pose.persist(); tick += 1 }
                    ), range: -40...40)
                }
            }
            .disabled(!model3D)

            Group {
                SettingsRow(label: "Shadow") {
                    Toggle("Soft shadow behind the phone", isOn: $shadow)
                }

                SettingsRow(label: "Reflection") {
                    Toggle("Mirror the phone on the surface below", isOn: $reflection)
                }
            }
            .disabled(model3D)

            SettingsRow(label: "") {
                Text(model3D
                    ? "Shadow and reflection apply to the frame artwork only."
                    : "Angle controls are available with the 3D model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onReceive(Timer.publish(every: 0.3, on: .main, in: .common).autoconnect()) { _ in
            if model3D { tick += 1 }
        }
    }

    private func isCurrent(_ preset: (name: String, yaw: Double, pitch: Double)) -> Bool {
        abs(pose.yaw * degrees - preset.yaw) < 1 && abs(pose.pitch * degrees - preset.pitch) < 1
    }

    private func slider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(label).frame(width: 40, alignment: .leading)
            Slider(value: value, in: range)
                .frame(width: 220)
            Text("\(Int(value.wrappedValue))°")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
        .font(.callout)
    }
}

// MARK: - Background

private struct BackgroundSettings: View {
    @AppStorage("backgroundPreset") private var backgroundPreset = 0
    @AppStorage("backgroundImagePath") private var backgroundImagePath = ""
    @AppStorage("backgroundColorHex") private var backgroundColorHex = ""
    @StateObject private var library = UserBackgrounds.shared
    @State private var showingImporter = false
    @State private var colorPanel = ColorPanelBridge()

    // 5 tiles + label column + padding must fit SettingsView's width (600):
    // 24 + 100 + 12 + (5·76 + 4·10) + 24 = 580, plus room for the scroll bar.
    private let tileSize = CGSize(width: 76, height: 54)
    private let spacing: CGFloat = 10
    private var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(tileSize.width), spacing: spacing), count: 5)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SettingsRow(label: "Gradients") {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: spacing) {
                        ForEach(BackgroundPreset.gradients) { preset in
                            tile(selected: backgroundPreset == preset.id) {
                                backgroundPreset = preset.id
                            } content: {
                                LinearGradient(
                                    colors: preset.colors,
                                    startPoint: .topLeading, endPoint: .bottomTrailing)
                            }
                            .help(preset.name)
                        }
                    }
                }

                if !SystemWallpapers.all.isEmpty {
                    SettingsRow(label: "macOS") {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: spacing) {
                            ForEach(SystemWallpapers.all) { wallpaper in
                                tile(selected: isSelected(path: wallpaper.url.path)) {
                                    select(path: wallpaper.url.path)
                                } content: {
                                    ImageThumbnail(url: wallpaper.thumbnail)
                                }
                                .help(wallpaper.name)
                            }
                        }
                    }
                }

                if !VideoWallpapers.all.isEmpty {
                    SettingsRow(label: "Animated") {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: spacing) {
                            ForEach(VideoWallpapers.all) { wallpaper in
                                tile(selected: isSelected(path: wallpaper.url.path)) {
                                    select(path: wallpaper.url.path)
                                } content: {
                                    VideoThumbnail(url: wallpaper.url)
                                }
                                .help(wallpaper.name)
                            }
                        }
                    }
                }

                SettingsRow(label: "Yours") {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: spacing) {
                        ForEach(library.items, id: \.self) { url in
                            tile(selected: isSelected(path: url.path)) {
                                select(path: url.path)
                            } content: {
                                if VideoBackground.isVideo(path: url.path) {
                                    VideoThumbnail(url: url)
                                } else {
                                    ImageThumbnail(url: url)
                                }
                            }
                            .contextMenu {
                                Button("Remove", role: .destructive) { remove(url) }
                            }
                        }

                        Button {
                            showingImporter = true
                        } label: {
                            plusLabel
                                .frame(width: tileSize.width, height: tileSize.height)
                                .background(
                                    Color.primary.opacity(0.1),
                                    in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .help("Add your own image or video")
                    }
                }

                SettingsRow(label: "Colors") {
                    HStack(spacing: spacing) {
                        ForEach(BackgroundPreset.solids) { preset in
                            swatch(selected: backgroundPreset == preset.id) {
                                backgroundPreset = preset.id
                            } fill: {
                                Circle().fill(preset.colors[0])
                            }
                            .help(preset.name)
                        }

                        customColorSwatch
                    }
                }

                SettingsRow(label: "") {
                    Text("Selected: \(selectionName)"
                        + (library.items.isEmpty ? "" : " · right-click your images to remove them"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
        }
        .frame(height: 480)
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.image, .movie],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            let added = urls.compactMap { library.add($0) }
            if let first = added.first { select(path: first.path) }
        }
    }

    // MARK: Pieces

    private var plusLabel: some View {
        Image(systemName: "plus")
            .font(.title2.weight(.light))
            .foregroundStyle(.secondary)
    }

    private func tile<Content: View>(
        selected: Bool, action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Button(action: action) {
            content()
                .frame(width: tileSize.width, height: tileSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(selectionRing(RoundedRectangle(cornerRadius: 8), selected: selected))
        }
        .buttonStyle(.plain)
    }

    private func swatch<Fill: View>(
        selected: Bool, action: @escaping () -> Void,
        @ViewBuilder fill: () -> Fill
    ) -> some View {
        Button(action: action) {
            fill()
                .frame(width: 50, height: 50)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                .overlay(selectionRing(Circle(), selected: selected))
        }
        .buttonStyle(.plain)
    }

    private func selectionRing<S: InsettableShape>(_ shape: S, selected: Bool) -> some View {
        shape
            .inset(by: -3)
            .strokeBorder(Color.accentColor, lineWidth: selected ? 3 : 0)
    }

    /// Shows the user's custom color (or a "+" before one is chosen); clicking
    /// opens the system color panel and applies changes live.
    private var customColorSwatch: some View {
        let custom = BackgroundColor.nsColor(hex: backgroundColorHex)
        return swatch(selected: backgroundPreset == BackgroundSelection.customColor) {
            colorPanel.show(initial: custom ?? .systemTeal) { color in
                backgroundColorHex = BackgroundColor.hex(color)
                backgroundPreset = BackgroundSelection.customColor
            }
            if custom != nil { backgroundPreset = BackgroundSelection.customColor }
        } fill: {
            ZStack {
                if let custom {
                    Circle().fill(Color(nsColor: custom))
                } else {
                    Circle().fill(Color.primary.opacity(0.1))
                    plusLabel
                }
            }
        }
        .help("Pick a custom color")
    }

    // MARK: Selection

    private var selectionName: String {
        switch backgroundPreset {
        case BackgroundSelection.video:
            return VideoWallpapers.all.first { $0.url.path == backgroundImagePath }?.name
                ?? "Your video"
        case BackgroundSelection.image:
            return SystemWallpapers.all.first { $0.url.path == backgroundImagePath }?.name
                ?? "Your image"
        case BackgroundSelection.customColor: return "Custom color"
        default: return BackgroundPreset.preset(backgroundPreset).name
        }
    }

    private func isSelected(path: String) -> Bool {
        (backgroundPreset == BackgroundSelection.image
            || backgroundPreset == BackgroundSelection.video)
            && backgroundImagePath == path
    }

    private func select(path: String) {
        backgroundImagePath = path
        backgroundPreset = VideoBackground.isVideo(path: path)
            ? BackgroundSelection.video : BackgroundSelection.image
    }

    private func remove(_ url: URL) {
        if isSelected(path: url.path) {
            backgroundPreset = 0
            backgroundImagePath = ""
        }
        library.remove(url)
    }
}

/// Drives NSColorPanel with a closure (SwiftUI's ColorPicker can't be styled
/// as a swatch).
@MainActor
private final class ColorPanelBridge: NSObject {
    private var onChange: ((NSColor) -> Void)?

    func show(initial: NSColor, onChange: @escaping (NSColor) -> Void) {
        self.onChange = onChange
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.color = initial
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        panel.orderFront(nil)
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        onChange?(sender.color)
    }
}

/// Downsampled thumbnail so big wallpapers don't bloat the settings grid.
private struct ImageThumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color.secondary.opacity(0.15)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            }
        }
        .clipped()
        .task(id: url) {
            image = await Task.detached(priority: .utility) {
                Self.thumbnail(url)
            }.value
        }
    }

    private nonisolated static func thumbnail(_ url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 400,
              ] as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }
}

/// First-second still of a video, for the settings grid.
private struct VideoThumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color.secondary.opacity(0.15)
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            }
            Image(systemName: "play.fill")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.9))
                .padding(5)
                .background(.black.opacity(0.35), in: Circle())
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(4)
        }
        .clipped()
        .task(id: url) {
            image = await Task.detached(priority: .utility) { () -> NSImage? in
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 400, height: 400)
                guard let cg = try? generator.copyCGImage(
                    at: CMTime(seconds: 1, preferredTimescale: 600), actualTime: nil)
                else { return nil }
                return NSImage(cgImage: cg, size: .zero)
            }.value
        }
    }
}

// MARK: - About

private struct AboutSettings: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 84, height: 84)
            Text("Present")
                .font(.title2.bold())
            Text(version)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Mirror your iPhone on your Mac with QuickTime-level latency, framed in a photoreal device bezel.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
                .padding(.top, 6)
            Link("github.com/oozou/present",
                 destination: URL(string: "https://github.com/oozou/present")!)
                .font(.callout)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
    }
}
