import Foundation

extension SceneSpec {
    /// The scene as currently configured in settings, read straight from user
    /// defaults. Exporters and the virtual camera use this (not a view's
    /// @AppStorage copy, which goes stale once captured in a closure).
    @MainActor
    static func current(capture: CaptureController) -> SceneSpec? {
        guard let streamSize = capture.streamSize else { return nil }
        let defaults = UserDefaults.standard
        func bool(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? fallback }
        func string(_ key: String, _ fallback: String) -> String { defaults.string(forKey: key) ?? fallback }

        let showBezel = bool("showBezel", true)
        let modelOverride = string("modelOverride", "")
        let inferred = PhoneModel.infer(from: streamSize)
        let identifier = modelOverride.isEmpty
            ? (capture.modelIdentifier ?? inferred.identifier)
            : modelOverride
        let style = SceneStyle(
            shadow: bool("phoneShadow", true),
            reflection: bool("phoneReflection", false),
            model3D: bool("phoneModel3D", false),
            modelID: PhoneModelSpec.resolve(override: modelOverride, device: capture.modelIdentifier).id)

        return SceneSpec(
            streamSize: streamSize,
            chrome: showBezel
                ? DeviceChrome.load(
                    modelIdentifier: identifier,
                    finish: string("deviceFinish", DeviceFinish.original.id))
                : nil,
            fallbackStyle: inferred.bezel,
            showBezel: showBezel,
            backgroundPresetID: defaults.object(forKey: "backgroundPreset") as? Int ?? 0,
            backgroundImagePath: string("backgroundImagePath", ""),
            backgroundColorHex: string("backgroundColorHex", ""),
            style: style)
    }
}
