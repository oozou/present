import SwiftUI

struct BackgroundPreset: Identifiable {
    let id: Int
    let name: String
    let colors: [Color]

    static let all: [BackgroundPreset] = [
        .init(id: 0, name: "Aurora", colors: [
            Color(red: 0.35, green: 0.20, blue: 0.65),
            Color(red: 0.10, green: 0.35, blue: 0.70),
            Color(red: 0.75, green: 0.30, blue: 0.55),
        ]),
        .init(id: 1, name: "Ocean", colors: [
            Color(red: 0.05, green: 0.25, blue: 0.45),
            Color(red: 0.05, green: 0.55, blue: 0.60),
        ]),
        .init(id: 2, name: "Sunset", colors: [
            Color(red: 0.95, green: 0.45, blue: 0.25),
            Color(red: 0.85, green: 0.25, blue: 0.50),
        ]),
        .init(id: 3, name: "Meadow", colors: [
            Color(red: 0.10, green: 0.45, blue: 0.30),
            Color(red: 0.30, green: 0.70, blue: 0.55),
        ]),
        .init(id: 4, name: "Graphite", colors: [
            Color(white: 0.28),
            Color(white: 0.10),
        ]),
        .init(id: 5, name: "Black", colors: [.black, .black]),
        .init(id: 6, name: "White", colors: [
            Color(white: 1.0),
            Color(white: 0.88),
        ]),
    ]
}

/// Renders the chosen background: a gradient preset, or a user-picked image.
struct BackgroundView: View {
    let presetID: Int
    let imagePath: String

    var body: some View {
        if presetID == -1, let image = NSImage(contentsOfFile: imagePath) {
            GeometryReader { geo in
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            }
            .ignoresSafeArea()
        } else {
            let preset = BackgroundPreset.all.first { $0.id == presetID } ?? BackgroundPreset.all[0]
            LinearGradient(colors: preset.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
        }
    }
}
