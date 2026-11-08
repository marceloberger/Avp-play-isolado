import Foundation

/// Supported recipe profiles are separate from installed/verified availability.
/// Historical 824 metadata stays decodable, but is never selected for a new attempt.
public enum ExperimentalRuntime183: String, Codable, Sendable, CaseIterable {
    case klepton824 = "824-a61188d"
    case klepton850 = "850-cc2856c"

    public static let permitted: [Self] = [.klepton850]
    public var minCommit: String { self == .klepton850 ? "cc2856c" : "a61188d" }
    public var label: String { self == .klepton850 ? RuntimePolicy177.label : "Klepton 824 a61188d (histórico)" }
    public var rules: String { self == .klepton850
        ? Klepton850RecipeRules.version + "/" + Klepton850RecipeRules.revision
        : Klepton824RecipeRules.version + "/" + Klepton824RecipeRules.revision }

    public func requirePermitted() throws {
        guard Self.permitted.contains(self) else {
            throw RecipeError.invalid("Perfil experimental histórico não permitido para novas tentativas. " + RuntimePolicy177.blocked)
        }
    }

    /// Uses the same full source, SDK and TLS overlay contract as Prepare/Build.
    /// No writes, downloads, fallback or changes to persisted pins.
    public func verifiedSource(at root: URL = RuntimePolicy177.sourceRoot,
                               analysis: LocalGenericTargetAnalysis) throws -> Toolchain {
        try requirePermitted()
        guard analysis.canAttemptGenericBuild else { throw RecipeError.invalid(analysis.blockers.joined(separator: "; ")) }
        return try RuntimePolicy177.source(at: root)
    }
}
