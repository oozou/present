import CoreGraphics

/// The visual style of the phone's frame, used when no simulator chrome
/// artwork is available for the model.
enum BezelStyle: String, CaseIterable, Identifiable {
    case dynamicIsland = "Dynamic Island"
    case notch = "Notch"
    case homeButton = "Home Button"

    var id: String { rawValue }
}

struct PhoneModel {
    let name: String
    let bezel: BezelStyle
    /// Representative hardware identifier (keys into simulator chrome artwork).
    let identifier: String

    /// Maps native screen resolutions to iPhone models. The mirrored stream
    /// arrives at the device's native pixel resolution, so the long side is a
    /// reliable fingerprint for which iPhone is connected.
    static func infer(from streamSize: CGSize?) -> PhoneModel {
        guard let size = streamSize else {
            return PhoneModel(name: "iPhone", bezel: .dynamicIsland, identifier: "iPhone18,1")
        }
        let longSide = Int(max(size.width, size.height))
        switch longSide {
        case 2868: return .init(name: "iPhone 16/17 Pro Max", bezel: .dynamicIsland, identifier: "iPhone18,2")
        case 2796: return .init(name: "iPhone 15/16 Plus · 14/15 Pro Max", bezel: .dynamicIsland, identifier: "iPhone17,2")
        case 2778: return .init(name: "iPhone 12/13 Pro Max · 14 Plus", bezel: .notch, identifier: "iPhone14,3")
        case 2736: return .init(name: "iPhone Air", bezel: .dynamicIsland, identifier: "iPhone18,4")
        case 2688: return .init(name: "iPhone XS Max · 11 Pro Max", bezel: .notch, identifier: "iPhone11,6")
        case 2622: return .init(name: "iPhone 16/17 Pro", bezel: .dynamicIsland, identifier: "iPhone18,1")
        case 2556: return .init(name: "iPhone 14/15 Pro · 15/16/17", bezel: .dynamicIsland, identifier: "iPhone17,3")
        case 2532: return .init(name: "iPhone 12/13/14", bezel: .notch, identifier: "iPhone14,5")
        case 2436: return .init(name: "iPhone X/XS · 11 Pro", bezel: .notch, identifier: "iPhone11,2")
        case 2340: return .init(name: "iPhone 12/13 mini", bezel: .notch, identifier: "iPhone14,4")
        case 1792: return .init(name: "iPhone XR/11", bezel: .notch, identifier: "iPhone12,1")
        case 1334, 1136: return .init(name: "iPhone SE", bezel: .homeButton, identifier: "iPhone12,8")
        default: return .init(name: "iPhone", bezel: .dynamicIsland, identifier: "iPhone18,1")
        }
    }

    /// Manual override choices for the frame menu.
    static let overrideChoices: [(name: String, identifier: String)] = [
        ("iPhone 17 Pro Max", "iPhone18,2"),
        ("iPhone 17 Pro", "iPhone18,1"),
        ("iPhone 17", "iPhone18,3"),
        ("iPhone Air", "iPhone18,4"),
        ("iPhone 16 Pro", "iPhone17,1"),
        ("iPhone 16", "iPhone17,3"),
        ("iPhone 13", "iPhone14,5"),
        ("iPhone SE", "iPhone12,8"),
    ]
}
