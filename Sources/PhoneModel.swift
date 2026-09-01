import CoreGraphics

/// The visual style of the phone's frame, inferred from the mirrored screen resolution.
enum BezelStyle: String, CaseIterable, Identifiable {
    case dynamicIsland = "Dynamic Island"
    case notch = "Notch"
    case homeButton = "Home Button"

    var id: String { rawValue }
}

struct PhoneModel {
    let name: String
    let bezel: BezelStyle

    /// Maps native screen resolutions to iPhone models. The mirrored stream
    /// arrives at the device's native pixel resolution, so the long side is a
    /// reliable fingerprint for which iPhone is connected.
    static func infer(from streamSize: CGSize?) -> PhoneModel {
        guard let size = streamSize else {
            return PhoneModel(name: "iPhone", bezel: .dynamicIsland)
        }
        let longSide = Int(max(size.width, size.height))
        switch longSide {
        case 2868: return .init(name: "iPhone 16/17 Pro Max", bezel: .dynamicIsland)
        case 2796: return .init(name: "iPhone 15/16 Plus · 14/15 Pro Max", bezel: .dynamicIsland)
        case 2778: return .init(name: "iPhone 12/13 Pro Max · 14 Plus", bezel: .notch)
        case 2736: return .init(name: "iPhone Air", bezel: .dynamicIsland)
        case 2688: return .init(name: "iPhone XS Max · 11 Pro Max", bezel: .notch)
        case 2622: return .init(name: "iPhone 16/17 Pro", bezel: .dynamicIsland)
        case 2556: return .init(name: "iPhone 14/15 Pro · 15/16/17", bezel: .dynamicIsland)
        case 2532: return .init(name: "iPhone 12/13/14", bezel: .notch)
        case 2436: return .init(name: "iPhone X/XS · 11 Pro", bezel: .notch)
        case 2340: return .init(name: "iPhone 12/13 mini", bezel: .notch)
        case 1792: return .init(name: "iPhone XR/11", bezel: .notch)
        case 1334, 1136: return .init(name: "iPhone SE", bezel: .homeButton)
        default: return .init(name: "iPhone", bezel: .dynamicIsland)
        }
    }
}
