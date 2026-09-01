import SwiftUI
import AVFoundation

/// Draws the phone: video (or placeholder) inside real simulator chrome when
/// available, else a drawn bezel. Adapts to portrait/landscape streams. The
/// mirrored stream already contains the Dynamic Island / notch pixels, so
/// nothing is drawn over the video.
struct PhoneView: View {
    @EnvironmentObject private var capture: CaptureController
    let showBezel: Bool
    /// Use simulator chrome artwork when available (else the drawn bezel).
    let useChrome: Bool
    /// Hardware identifier override ("" = auto).
    let modelOverride: String

    private var screenAspect: CGSize {
        if let size = capture.streamSize, size.width > 0, size.height > 0 {
            return size
        }
        return CGSize(width: 1179, height: 2556) // iPhone 15-class portrait
    }

    private var chromeIdentifier: String {
        if !modelOverride.isEmpty { return modelOverride }
        return capture.modelIdentifier ?? PhoneModel.infer(from: capture.streamSize).identifier
    }

    var body: some View {
        GeometryReader { geo in
            if showBezel, useChrome,
               let chrome = DeviceChrome.load(modelIdentifier: chromeIdentifier) {
                chromeBody(chrome, available: geo.size)
            } else {
                fallbackBody(available: geo.size)
            }
        }
    }

    // MARK: - Simulator chrome

    @ViewBuilder
    private func chromeBody(_ chrome: DeviceChrome, available: CGSize) -> some View {
        let s = screenAspect
        let landscape = s.width > s.height
        let portraitAspect = landscape ? s.height / s.width : s.width / s.height
        let f = chrome.screenFraction(portraitAspect: portraitAspect)
        let fracW = landscape ? f.height : f.width
        let fracH = landscape ? f.width : f.height
        let c = chrome.compositeSize
        let outerAspect = landscape ? c.height / c.width : c.width / c.height

        let ow = min(available.width, available.height * outerAspect)
        let oh = ow / outerAspect
        let sw = ow * fracW
        let sh = oh * fracH

        // Portrait-oriented frame stack (buttons behind the body), rotated
        // as one unit for landscape streams.
        let pw = landscape ? oh : ow
        let ph = landscape ? ow : oh
        let frameStack = ZStack(alignment: .topLeading) {
            ForEach(chrome.buttons) { button in
                ChromeButtonView(button: button, scale: pw / chrome.compositeSize.width)
            }
            Image(nsImage: chrome.composite)
                .resizable()
                .frame(width: pw, height: ph)
                .allowsHitTesting(false) // clicks fall through to the buttons
        }
        .frame(width: pw, height: ph)

        ZStack {
            rotatable(frameStack, width: ow, height: oh, landscape: landscape)
                .shadow(color: .black.opacity(0.4), radius: ow * 0.05, y: ow * 0.015)

            screen
                .frame(width: sw, height: sh)
                .mask {
                    if let mask = chrome.mask {
                        rotatable(Image(nsImage: mask).resizable(),
                                  width: sw, height: sh, landscape: landscape)
                    } else {
                        RoundedRectangle(
                            cornerRadius: min(sw, sh) * 0.11, style: .continuous)
                    }
                }
        }
        .frame(width: available.width, height: available.height)
    }

    /// Lays out portrait artwork, rotated 90° when the stream is landscape.
    @ViewBuilder
    private func rotatable(_ image: some View, width: CGFloat, height: CGFloat, landscape: Bool) -> some View {
        if landscape {
            image
                .frame(width: height, height: width)
                .rotationEffect(.degrees(90))
                .frame(width: width, height: height)
        } else {
            image.frame(width: width, height: height)
        }
    }

    // MARK: - Drawn fallback

    private var fallbackStyle: BezelStyle {
        PhoneModel.infer(from: capture.streamSize).bezel
    }

    private func fallbackBody(available: CGSize) -> some View {
        let m = PhoneMetrics(
            available: available,
            screenAspect: screenAspect,
            style: showBezel ? fallbackStyle : nil)

        return ZStack {
            if showBezel {
                RoundedRectangle(cornerRadius: m.outerCornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(white: 0.30), Color(white: 0.10), Color(white: 0.22)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(
                        RoundedRectangle(cornerRadius: m.outerCornerRadius, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
                    .frame(width: m.outerSize.width, height: m.outerSize.height)
                    .shadow(color: .black.opacity(0.45), radius: m.unit * 1.6, y: m.unit * 0.6)
            }

            screen
                .frame(width: m.screenSize.width, height: m.screenSize.height)
                .clipShape(RoundedRectangle(cornerRadius: m.screenCornerRadius, style: .continuous))

            if showBezel, fallbackStyle == .homeButton {
                let landscape = m.screenSize.width > m.screenSize.height
                Circle()
                    .strokeBorder(Color.white.opacity(0.35), lineWidth: m.unit * 0.12)
                    .frame(width: m.unit * 2.6, height: m.unit * 2.6)
                    .frame(
                        width: m.outerSize.width, height: m.outerSize.height,
                        alignment: landscape ? .trailing : .bottom)
                    .offset(
                        x: landscape ? -m.unit * 0.9 : 0,
                        y: landscape ? 0 : -m.unit * 0.9)
            }
        }
        .frame(width: available.width, height: available.height)
    }

    // MARK: - Screen content

    @ViewBuilder
    private var screen: some View {
        if capture.isStreaming {
            PreviewView(session: capture.session)
                .overlay(islandOverlay)
        } else {
            placeholder
        }
    }

    // Declared so SwiftUI re-renders live while the island is calibrated
    // with the ⌥-arrow shortcuts (the values feed DynamicIsland.rect).
    @AppStorage("islandY") private var islandY = 41.0
    @AppStorage("islandHeight") private var islandHeight = 111.0
    @AppStorage("islandWidth") private var islandWidth = 378.0
    @AppStorage("islandMode") private var islandMode = "auto"

    /// Idle mirror streams omit the Dynamic Island, so a black pill is drawn
    /// in. It fades out whenever the stream renders the island itself (an
    /// animation or Live Activity), detected by sampling the frames.
    @ViewBuilder
    private var islandOverlay: some View {
        let _ = (islandY, islandHeight, islandWidth)
        if islandMode != "off", let island = DynamicIsland.rect(streamSize: screenAspect) {
            let calibrating = islandMode == "always"
            GeometryReader { geo in
                let scaleX = geo.size.width / screenAspect.width
                let scaleY = geo.size.height / screenAspect.height
                Capsule()
                    // Calibration mode: translucent red diff so the pill can
                    // be compared against the stream's own island underneath.
                    .fill(calibrating ? Color.red.opacity(0.4) : Color.black)
                    .overlay {
                        if calibrating {
                            Capsule().strokeBorder(Color.red, lineWidth: 1)
                        }
                    }
                    .frame(width: island.width * scaleX, height: island.height * scaleY)
                    .offset(x: island.minX * scaleX, y: island.minY * scaleY)
                    .opacity(calibrating || !capture.streamShowsIsland ? 1 : 0)
                    // Reappear fast (the stream's island vanishes abruptly);
                    // hiding can be gentler — both are black while overlapping.
                    .animation(
                        .easeOut(duration: capture.streamShowsIsland ? 0.2 : 0.08),
                        value: capture.streamShowsIsland)
            }
            .allowsHitTesting(false)
        }
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(
                colors: [Color(white: 0.12), Color(white: 0.05)],
                startPoint: .top, endPoint: .bottom)
            VStack(spacing: 14) {
                Image(systemName: "iphone.gen3")
                    .font(.system(size: 44, weight: .thin))
                    .foregroundStyle(.secondary)
                switch capture.status {
                case .accessDenied:
                    Text("Camera access denied")
                        .font(.headline)
                    Text("Enable it in System Settings → Privacy & Security → Camera, then relaunch.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                case .error(let message):
                    Text("Couldn't start the stream")
                        .font(.headline)
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                default:
                    Text("Connect your iPhone")
                        .font(.headline)
                    Text("Plug in via USB-C, unlock the phone,\nand tap “Trust” if asked.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(24)
        }
        .colorScheme(.dark)
    }
}

/// A clickable side button (volume/power/action). Sits behind the phone body
/// showing its protruding sliver; a click slides it inward and swaps to the
/// pressed artwork, like the Simulator does.
private struct ChromeButtonView: View {
    let button: ChromeButton
    /// Points-on-screen per composite point.
    let scale: CGFloat

    @State private var pressed = false

    var body: some View {
        let w = button.size.width * scale
        let h = button.size.height * scale
        let minX = (pressed ? button.tuckedMinX : button.restMinX) * scale

        Image(nsImage: pressed ? (button.imageDown ?? button.image) : button.image)
            .resizable()
            .frame(width: w, height: h)
            .offset(x: minX, y: button.y * scale)
            .animation(.easeOut(duration: 0.09), value: pressed)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in pressed = true }
                    .onEnded { _ in pressed = false })
            .help(button.id)
    }
}

/// Computes screen/bezel geometry for the drawn fallback so the whole phone
/// fits the available space.
struct PhoneMetrics {
    let screenSize: CGSize
    let outerSize: CGSize
    let screenCornerRadius: CGFloat
    let outerCornerRadius: CGFloat
    /// Scale unit: 1/20 of the screen's short side.
    let unit: CGFloat

    init(available: CGSize, screenAspect: CGSize, style: BezelStyle?) {
        let aspect = screenAspect.width / max(screenAspect.height, 1)
        let landscape = aspect > 1

        // Bezel thickness as a fraction of the screen's short side.
        let sideFrac: CGFloat
        let endFrac: CGFloat // extra chin on top+bottom (home-button phones)
        switch style {
        case .homeButton:
            sideFrac = 0.045
            endFrac = 0.28
        case .dynamicIsland, .notch:
            sideFrac = 0.05
            endFrac = 0.05
        case nil:
            sideFrac = 0
            endFrac = 0
        }

        var screenW: CGFloat
        var screenH: CGFloat
        if landscape {
            screenH = available.height
            screenW = screenH * aspect
        } else {
            screenW = available.width
            screenH = screenW / aspect
        }
        let short = { min(screenW, screenH) }
        var outerW = screenW + short() * 2 * (landscape ? endFrac : sideFrac)
        var outerH = screenH + short() * 2 * (landscape ? sideFrac : endFrac)
        let scale = min(available.width / outerW, available.height / outerH, 1)
        screenW *= scale
        screenH *= scale
        outerW *= scale
        outerH *= scale

        screenSize = CGSize(width: screenW, height: screenH)
        outerSize = CGSize(width: outerW, height: outerH)
        unit = min(screenW, screenH) / 20

        switch style {
        case .homeButton:
            screenCornerRadius = unit * 0.3
            outerCornerRadius = unit * 2.2
        case .dynamicIsland, .notch:
            screenCornerRadius = unit * 2.4
            outerCornerRadius = unit * 2.4 + min(outerW - screenW, outerH - screenH) / 2
        case nil:
            screenCornerRadius = unit * 0.8
            outerCornerRadius = 0
        }
    }
}
