import Foundation

/// Identifies the exact signed output and effective build environment. Local evidence, not attestation.
public struct LocalAPKBuildEvidence: Codable, Sendable, Equatable {
    public var signedBuildSHA256: String
    public var unsignedBuildSHA256: String
    public var recipeSHA256: String
    public var assetsSHA256: String?
    public var settings: [String: String]
    /// Separate manifests; nil on older receipts. Neither replaces per-file validation.
    public var requiredFilesSHA256: String?
    public var optionalFilesSHA256: String?

    public static func dependencyHash(_ variant: LocalAPKVariant, recipe: Recipe, required: Bool,
                                      selection: FetchSelection) throws -> String {
        let names = Set(FetchPlan.wantedFiles(recipe: recipe, selection: selection)
            .filter { $0.role != "apk" && $0.required == required }.map(\.name))
        return try digest((variant.assets ?? []).filter { names.contains($0.name) }
            .map { ["name": $0.name, "sha256": $0.sha256, "size": String($0.size)] }
            .sorted { $0["name", default: ""] < $1["name", default: ""] })
    }

    /// Read initial defaults from the product, never from preferences that may change during compilation.
    public func applyingProductDefaults(to request: InstallRequest) -> InstallRequest {
        var result = request
        if let room = settings["Info.KLRoomGuardDefault"] { result.roomMeasuring = room == "1" }
        if let language = settings["Info.KLGameLanguageDefault"] { result.gameLanguage = language }
        if let mode = settings["Info.KLControllerModeDefault"].flatMap(ControllerMode.init(rawValue:)) {
            result.controllerMode = mode
        }
        if let mode = settings["Info.KLFrameGenDefault"].flatMap(FrameGeneration.init(rawValue:)) { result.frameGeneration = mode }
        if let value = settings["Info.KLScotland2CoreMods"] { result.coreMods = value == "1" }
        if let value = settings["Info.KLSurrealAvailable"] { result.surrealSupport = value != "NO" }
        return result
    }

    static func digest<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return Hashing.sha256(of: try encoder.encode(value))
    }
    public static func recipeHash(_ recipe: Recipe) throws -> String { try digest(recipe) }
    public static func assetsHash(_ variant: LocalAPKVariant) throws -> String {
        // Content and destination identity, independent of the source drive's mount path.
        try digest((variant.assets ?? []).map { ["name": $0.name, "sha256": $0.sha256, "size": String($0.size), "destination": $0.destination ?? "", "additional": String($0.isAdditional ?? false)] }
            .sorted { $0["name", default: ""] < $1["name", default: ""] })
    }
}

public struct InstalledBuild: Sendable {
    public var expires: Date
    public var evidence: LocalAPKBuildEvidence
}
