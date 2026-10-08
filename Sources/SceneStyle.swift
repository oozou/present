import Foundation

/// Presentation effects for the phone. Shared by the live view (SwiftUI) and
/// the exporters (CoreImage), so both render the same look.
struct SceneStyle: Equatable {
    /// Degrees. Positive yaw turns the right edge away from the viewer.
    var yaw = 0.0
    /// Degrees. Positive pitch tilts the top edge away.
    var pitch = 0.0
    var shadow = true
    var reflection = false
    /// Render the USDZ phone model (drag to rotate) instead of the flat frame artwork.
    var model3D = false
    /// `PhoneModelSpec` id used when `model3D` is on.
    var modelID = "air"

    var isTilted: Bool { abs(yaw) > 0.5 || abs(pitch) > 0.5 }
    /// Whether the phone is drawn on a projected plane (tilt or reflection)
    /// rather than flat.
    var needsPlane: Bool { isTilted || reflection }

    /// Named tilt presets shown in settings.
    static let tiltPresets: [(name: String, yaw: Double, pitch: Double)] = [
        ("Flat", 0, 0),
        ("Left", -24, 6),
        ("Right", 24, 6),
        ("Hero", -28, 12),
    ]

    /// How far the reflection extends below the phone, as a fraction of its height.
    static let reflectionDepth = 0.4
}
