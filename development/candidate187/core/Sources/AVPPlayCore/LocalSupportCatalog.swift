import Foundation

/// Offline investigation metadata, separate from installable Recipe data. A catalog
/// match supplies diagnostics only and cannot enable a target, purchase or download.
public struct LocalSupportCatalog: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public let requestedTitle: String
        public let title: String
        public let package: String?
        public let target: String?
        public let versionName: String?
        public let versionCode: Int?
        public let classification: String
        public let limitation: String
        public let evidence: [String]
    }
    public let schema: Int
    public let entries: [Entry]

    public static func load(at url: URL? = Bundle.main.resourceURL?.appendingPathComponent("local-support-824.json")) -> LocalSupportCatalog? {
        guard let url, let bytes = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(Self.self, from: bytes), catalog.schema == 1 else { return nil }
        return catalog
    }

    public func diagnostics(package: String, versionCode: String?) -> [String] {
        guard let entry = entries.first(where: { $0.package == package }) else { return [] }
        var result = ["Catálogo offline: \(entry.title) · classe \(entry.classification) (evidência externa, sem teste local)"]
        if let version = entry.versionCode, String(version) != versionCode {
            result.append("Versão observada diverge do catálogo (\(version)); não herdar sua compatibilidade")
        }
        if let target = entry.target { result.append("Target publicado: \(target); isso não comprova receita ou execução") }
        result.append(entry.limitation)
        return result
    }
}
