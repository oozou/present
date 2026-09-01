import SwiftUI
import AVFoundation

/// Draws the phone: video (or placeholder) inside a device bezel with the
/// correct cutout for the connected model. Adapts to portrait/landscape streams.
struct PhoneView: View {
    @EnvironmentObject private var capture: CaptureController
    let showBezel: Bool
    let bezelOverride: BezelStyle?

    private var screenAspect: CGSize {
        if let size = capture.streamSize, size.width > 0, size.height > 0 {
            return size
        }
        return CGSize(width: 1179, height: 2556) // iPhone 15-class portrait
    }

    private var bezelStyle: BezelStyle {
        bezelOverride ?? PhoneModel.infer(from: capture.streamSize).bezel
    }

    var body: some View {
        GeometryReader { geo in
            let m = PhoneMetrics(
                available: geo.size,
                screenAspect: screenAspect,
                style: showBezel ? bezelStyle : nil)

            ZStack {
                if showBezel {
                    bezelBody(m)
                }

                screen
                    .frame(width: m.screenSize.width, height: m.screenSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: m.screenCornerRadius, style: .continuous))

                if showBezel {
                    cutout(m)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .animation(.easeInOut(duration: 0.25), value: showBezel)
        }
    }

    @ViewBuilder
    private var screen: some View {
        if capture.isStreaming {
            PreviewView(session: capture.session)
        } else {
            placeholder
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
    }

    private func bezelBody(_ m: PhoneMetrics) -> some View {
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

    @ViewBuilder
    private func cutout(_ m: PhoneMetrics) -> some View {
        let landscape = m.screenSize.width > m.screenSize.height
        switch bezelStyle {
        case .dynamicIsland:
            let w = m.unit * 6.4
            let h = m.unit * 1.9
            Capsule()
                .fill(.black)
                .frame(width: landscape ? h : w, height: landscape ? w : h)
                .frame(
                    width: m.screenSize.width, height: m.screenSize.height,
                    alignment: landscape ? .leading : .top)
                .padding(landscape ? .leading : .top, 0)
                .offset(
                    x: landscape ? m.unit * 0.55 : 0,
                    y: landscape ? 0 : m.unit * 0.55)

        case .notch:
            let w = m.unit * 10.5
            let h = m.unit * 1.7
            if landscape {
                // Rotated 90°: flat edge sits on the leading screen edge.
                NotchShape()
                    .fill(.black)
                    .frame(width: w, height: h)
                    .rotationEffect(.degrees(90))
                    .frame(
                        width: m.screenSize.width, height: m.screenSize.height,
                        alignment: .leading)
                    .offset(x: (h - w) / 2)
            } else {
                NotchShape()
                    .fill(.black)
                    .frame(width: w, height: h)
                    .frame(
                        width: m.screenSize.width, height: m.screenSize.height,
                        alignment: .top)
            }

        case .homeButton:
            Circle()
                .strokeBorder(Color.white.opacity(0.35), lineWidth: m.unit * 0.12)
                .frame(width: m.unit * 2.6, height: m.unit * 2.6)
                .frame(
                    width: m.outerSize.width, height: m.outerSize.height,
                    alignment: landscape ? .trailing : .bottom)
                .padding(landscape ? .trailing : .bottom, 0)
                .offset(
                    x: landscape ? -m.unit * 0.9 : 0,
                    y: landscape ? 0 : -m.unit * 0.9)
        }
    }
}

/// Classic notch: flat top edge, rounded bottom corners.
struct NotchShape: Shape {
    func path(in rect: CGRect) -> Path {
        let r = rect.height * 0.5
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX - r, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - r),
            control: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// Computes screen/bezel geometry so the whole phone fits the available space.
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

        // Solve for the largest screen that fits with its bezel.
        // shortSide s; screen = portrait ? (s, s/aspect) : (s*aspect... )
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
