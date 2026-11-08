import Foundation

/// Upstream comparison with an explicit unknown outcome when local evidence is incomplete.
public enum LocalPrognosis170 {
    public static func assess(_ fingerprint: Fingerprint, runtime: RuntimeInterface?, references: [ReferenceFingerprint]) -> Prognosis? {
        guard let runtime, !runtime.functions.values.allSatisfy({ $0.isEmpty }),
              !references.isEmpty, fingerprint.format == Fingerprint.currentFormat, !fingerprint.architectures.isEmpty,
              !fingerprint.libraries.isEmpty,
              !fingerprint.imported.values.allSatisfy({ $0.isEmpty }) || fingerprint.graphics.vulkan || fingerprint.graphics.gles || !fingerprint.interfaces.isEmpty else { return nil }
        return Prognosis.make(fingerprint, runtime: runtime, references: references)
    }
}

/// Consent is evaluated for an explicit send action; importing or calculating never authorizes submission.
public enum FingerprintConsent170 {
    public static func allows(enabled: Bool, explicitAction: Bool, online: Bool, game: String?) -> Bool {
        guard enabled, explicitAction, online, let game else { return false }
        return CatalogGame.isIdentifier(game) || (game.hasPrefix("steam:") && CatalogGame.isIdentifier(String(game.dropFirst(6))))
    }
}
