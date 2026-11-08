import Foundation

/// Explicit, variant-scoped selection. Never inferred from a team or another game.
public struct LocalBundleIdentity: Codable, Equatable, Sendable {
    public var destination: String
    public var source: String

    public init(destination: String, source: String) {
        self.destination = destination; self.source = source
    }

    public func validate(target: String) throws {
        guard [source, destination].allSatisfy({ SigningRecord.isSafeBundleId($0)
            && $0.hasSuffix(".target." + target) }) else {
            throw ToolchainError.signingBlocked("Informe os Bundle IDs completos do mesmo jogo, sem espaços. Nenhum identificador foi alterado.")
        }
    }

    public func apply(to request: inout InstallRequest, target: String) throws {
        try validate(target: target)
        guard request.localAPKVariantID != nil, request.reuseBuildOnly == true else {
            throw ToolchainError.signingBlocked("A identidade explícita exige reutilizar um Build only local concluído; nova compilação bloqueada.")
        }
        request.bundleId = destination
        request.preservedBuildBundleID = source
    }
}
