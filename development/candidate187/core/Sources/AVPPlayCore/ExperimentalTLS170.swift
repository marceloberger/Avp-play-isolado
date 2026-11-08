import Foundation

/// An explicitly versioned source overlay, applied only after copying the verified
/// 850 payload into a new build-only workspace. Never changes an installed runtime.
enum ExperimentalTLS170 {
    struct Overlay: Decodable {
        struct File: Decodable { let path: String; let resource: String; let originalSHA256: String; let correctedSHA256: String }
        let revision: String
        let files: [File]
    }
    static func apply(to workspace: URL) throws {
        guard let manifest = Bundle.module.url(forResource: "tls170-overlay", withExtension: "json") else {
            throw RecipeError.invalid("Overlay TLS 170 ausente; compilação experimental bloqueada.")
        }
        let data = try Data(contentsOf: manifest)
        let overlay = try JSONDecoder().decode(Overlay.self, from: data)
        let marker = workspace.appendingPathComponent(".experimental-tls170.json")
        guard !FileManager.default.fileExists(atPath: marker.path), overlay.files.count == 4 else {
            throw RecipeError.invalid("Workspace TLS experimental já usado ou manifesto inválido.")
        }
        // Validate all inputs before changing any source in the new copy.
        let changes: [(URL, Data)] = try overlay.files.map { entry in
            guard Recipe.isSafeRelativePath(entry.path), Recipe.isSafeName(entry.resource),
                  let resource = Bundle.module.url(forResource: entry.resource, withExtension: nil) else {
                throw RecipeError.invalid("Fonte do overlay TLS ausente ou inválida.")
            }
            let target = workspace.appendingPathComponent(entry.path)
            let bytes = try Data(contentsOf: resource)
            guard try Hashing.sha256(of: target) == entry.originalSHA256,
                  Hashing.sha256(of: bytes) == entry.correctedSHA256 else {
                throw RecipeError.invalid("Fontes Klepton 850 divergentes; overlay TLS recusado: \(entry.path)")
            }
            return (target, bytes)
        }
        for (target, bytes) in changes { try bytes.write(to: target, options: .atomic) }
        try data.write(to: marker, options: .atomic)
    }
}
