import SwiftUI

struct BackgroundPreset: Identifiable {
    let id: Int
    let name: String
    let rgb: [(Double, Double, Double)]

    var colors: [Color] { rgb.map { Color(red: $0.0, green: $0.1, blue: $0.2) } }
    var cgColors: [CGColor] { rgb.map { CGColor(red: $0.0, green: $0.1, blue: $0.2, alpha: 1) } }

    static let all: [BackgroundPreset] = [
        .init(id: 0, name: "Aurora", rgb: [(0.35, 0.20, 0.65), (0.10, 0.35, 0.70), (0.75, 0.30, 0.55)]),
        .init(id: 1, name: "Ocean", rgb: [(0.05, 0.25, 0.45), (0.05, 0.55, 0.60)]),
        .init(id: 2, name: "Sunset", rgb: [(0.95, 0.45, 0.25), (0.85, 0.25, 0.50)]),
        .init(id: 3, name: "Meadow", rgb: [(0.10, 0.45, 0.30), (0.30, 0.70, 0.55)]),
        .init(id: 4, name: "Graphite", rgb: [(0.28, 0.28, 0.28), (0.10, 0.10, 0.10)]),
        .init(id: 5, name: "Black", rgb: [(0, 0, 0), (0, 0, 0)]),
        .init(id: 6, name: "White", rgb: [(1.0, 1.0, 1.0), (0.88, 0.88, 0.88)]),
    ]

    static func preset(_ id: Int) -> BackgroundPreset {
        all.first { $0.id == id } ?? all[0]
    }
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
            LinearGradient(
                colors: BackgroundPreset.preset(presetID).colors,
                startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
        }
    }
}
