import Foundation

/// Preferences used only when creating a new build request. Saved Jobs contain a resolved snapshot,
/// so changing these values never edits queued or historical work.
public struct RuntimeBuildPreferences: Codable, Equatable, Sendable {
    public static let surrealSupportKey = "surrealSupport"
    public static let controllerModeKey = ControllerMode.preferenceKey
    public static let frameGenerationKey = "frameGenerationDefault"
    public static let surrealSDKKey = "surrealSDKDefault"

    public var surrealSupport: Bool
    public var controllerMode: ControllerMode
    public var frameGeneration: FrameGeneration
    public var surrealSDK: SurrealSDKPolicy

    public init(surrealSupport: Bool = true, controllerMode: ControllerMode = .standard,
                frameGeneration: FrameGeneration = .automatic, surrealSDK: SurrealSDKPolicy = .verified) {
        self.surrealSupport = surrealSupport
        self.controllerMode = controllerMode
        self.frameGeneration = frameGeneration
        self.surrealSDK = surrealSDK
    }

    /// Missing keys are the pre-feature defaults: Surreal enabled, standard controllers,
    /// Klepton target default for Frame Generation, and the verified Surreal SDK.
    public static func load(defaults: UserDefaults = DataLocation.preferences) -> Self {
        let mode = defaults.string(forKey: controllerModeKey).flatMap(ControllerMode.init(rawValue:)) ?? .standard
        let frame = defaults.string(forKey: frameGenerationKey).flatMap(FrameGeneration.init(rawValue:)) ?? .automatic
        let sdk = defaults.string(forKey: surrealSDKKey).flatMap(SurrealSDKPolicy.init(rawValue:)) ?? .verified
        return Self(surrealSupport: defaults.object(forKey: surrealSupportKey) as? Bool ?? true,
                    controllerMode: mode, frameGeneration: frame, surrealSDK: sdk)
    }

    public func save(defaults: UserDefaults = DataLocation.preferences) {
        defaults.set(surrealSupport, forKey: Self.surrealSupportKey)
        defaults.set(controllerMode.rawValue, forKey: Self.controllerModeKey)
        defaults.set(frameGeneration.rawValue, forKey: Self.frameGenerationKey)
        defaults.set(surrealSDK.rawValue, forKey: Self.surrealSDKKey)
    }

    /// Per-game overrides take precedence. A disabled Surreal backend always resolves to standard
    /// controller input for the build; the stored global choice is retained if support is enabled later.
    public func resolve(overrides: RuntimeBuildOverrides = .init()) -> ResolvedRuntimeBuildPreferences {
        let enabled = overrides.surrealSupport ?? surrealSupport
        return ResolvedRuntimeBuildPreferences(
            surrealSupport: enabled,
            controllerMode: enabled ? (overrides.controllerMode ?? controllerMode) : .standard,
            frameGeneration: overrides.frameGeneration ?? frameGeneration,
            surrealSDK: overrides.surrealSDK ?? surrealSDK)
    }
}

public struct RuntimeBuildOverrides: Equatable, Sendable {
    public var surrealSupport: Bool?
    public var controllerMode: ControllerMode?
    public var frameGeneration: FrameGeneration?
    public var surrealSDK: SurrealSDKPolicy?
    public init(surrealSupport: Bool? = nil, controllerMode: ControllerMode? = nil,
                frameGeneration: FrameGeneration? = nil, surrealSDK: SurrealSDKPolicy? = nil) {
        self.surrealSupport = surrealSupport
        self.controllerMode = controllerMode
        self.frameGeneration = frameGeneration
        self.surrealSDK = surrealSDK
    }
}

public struct ResolvedRuntimeBuildPreferences: Equatable, Sendable {
    public let surrealSupport: Bool
    public let controllerMode: ControllerMode
    public let frameGeneration: FrameGeneration
    public let surrealSDK: SurrealSDKPolicy
}
