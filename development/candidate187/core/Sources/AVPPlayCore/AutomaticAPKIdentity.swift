import Foundation

/// Public package/AppID bindings, bundled offline. Identity evidence never asserts playability,
/// an APK hash, content completeness, ownership or an engine for an uninspected APK.
public struct AutomaticAPKIdentity: Codable, Sendable, Equatable {
    public let title: String
    public let package: String
    public let appID: String
    public let source: String
    public let catalogStatus: String?
    public let obbDirectory: String?
    public let requiresExternalContent: Bool?
    public let targetVersionCode: String?
    public let targetEngine: String?
    public let targetEntrypoint: String?

    public init(title: String, package: String, appID: String, source: String, catalogStatus: String? = nil, obbDirectory: String? = nil, requiresExternalContent: Bool? = nil, targetVersionCode: String? = nil, targetEngine: String? = nil, targetEntrypoint: String? = nil) {
        self.title = title; self.package = package; self.appID = appID; self.source = source; self.catalogStatus = catalogStatus
        self.obbDirectory = obbDirectory; self.requiresExternalContent = requiresExternalContent
        self.targetVersionCode = targetVersionCode; self.targetEngine = targetEngine; self.targetEntrypoint = targetEntrypoint
    }

    public var isValid: Bool {
        guard Recipe.isSafeName(package), package.contains("."), LocalExperimentalTarget.isValidAppID(appID),
              let url = URL(string: source), url.scheme == "https", url.query == nil, url.fragment == nil,
              url.user == nil, url.password == nil else { return false }
        let catalog = url.host == "avpplay.martek.de" && url.path == "/api/v1/games/\(appID)"
        let parts = url.path.split(separator: "/").map(String.init)
        let publicRecipe = url.host == "github.com" && parts.count == 6
            && Array(parts.prefix(3)) == ["myMartek", "avp-play", "blob"]
            && parts[3].count == 40 && parts[3].allSatisfy(\.isHexDigit)
            && parts[4] == "recipes" && parts[5].hasSuffix(".json") && Recipe.isSafeName(parts[5])
        return (catalog || publicRecipe) && !title.isEmpty
            && (obbDirectory == nil || obbDirectory == "obb" || obbDirectory == "Android/obb/\(package)")
    }

    public static var bundled: [Self] {
        guard let url = Bundle.module.url(forResource: "community-identities166", withExtension: "json"),
              let bytes = try? Data(contentsOf: url), let entries = try? JSONDecoder().decode([Self].self, from: bytes)
        else { return [] }
        return entries.filter(\.isValid)
    }

    /// Conflicting bindings fail closed. A package name is never converted into a numeric ID.
    public static func resolve(package: String, entries: [Self] = bundled) -> Self? {
        let matches = entries.filter { $0.package == package && $0.isValid }
        guard Set(matches.map(\.appID)).count == 1 else { return nil }
        return matches.sorted { $0.source < $1.source }.first
    }
}

public extension LocalProvisionalRecipe {
    var genericOBBDirectory: String? {
        let target = experimentalTarget?.target ?? automaticIdentity.map { "x" + $0.appID }
        if let directory = automaticIdentity?.obbDirectory,
           directory == "Android/obb/" + package, Recipe.isSafeRelativePath(directory) {
            return "android-files/" + directory
        }
        return RecipeValidation176.obbDirectory(target: target, package: package,
            engine: genericAnalysis.engine, version: 850)
    }

    var automaticIdentity: AutomaticAPKIdentity? {
        AutomaticAPKIdentity.resolve(package: package) ?? onlineIdentity186.flatMap {
            $0.package == package && $0.isValid ? $0 : nil
        }
    }

    /// Pure analysis. Unknown identity and unsupported engines remain inspectable, with actions blocked.
    var automaticTargetBlockers: [String] {
        var result = genericAnalysis.blockers
        if automaticIdentity == nil {
            result.append("Meta AppID sem vínculo público inequívoco com este package nos catálogos consultados. runtime selecionado exige x<AppID real>; análise disponível, Prepare e Build only bloqueados.")
        }
        if let code = automaticIdentity?.targetVersionCode, code != versionCode {
            result.append("O target específico do runtime selecionado fixa conteúdo da versão \(code); esta versão do APK requer uma receita adaptada.")
        }
        if let expected = automaticIdentity?.targetEngine,
           let engine = genericAnalysis.engine, expected != Klepton850RecipeRules.engineName(engine) {
            result.append("Engine observada diverge do target específico publicado no runtime selecionado: " + expected)
        }
        if let entry = automaticIdentity?.targetEntrypoint, entry != genericAnalysis.entrypoint {
            result.append("Entrypoint do APK diverge do target específico publicado no runtime selecionado.")
        }
        if automaticIdentity?.catalogStatus == "incompatible" {
            result.append("O catálogo público registra incompatibilidade desta edição. Análise preservada; é necessária uma receita adaptada com evidência técnica antes de habilitar ações.")
        }
        return result
    }
}

/// Offline evidence wins. An incomplete search, disagreement, or unavailable service yields no identity.
public extension AutomaticAPKIdentity {
    static func resolveWithOnlineFallback(package: String, offline: [Self] = bundled,
        fetchPage: @Sendable (String, Int) async throws -> CatalogClient.Page = { query, page in
            try await CatalogClient().identityPage(package: query, page: page)
        }) async throws -> Self? {
        let local = offline.filter { $0.package == package && $0.isValid }
        if !local.isEmpty { return resolve(package: package, entries: local) }
        // Catalog queries are limited to 80 characters. Never search a truncated identity.
        guard Recipe.isSafeName(package), package.contains("."), package.count <= 80 else { return nil }
        var matches: [CatalogGame] = []
        for page in 0..<100 {
            try Task.checkCancellation()
            let result = try await fetchPage(package, page)
            guard result.games.allSatisfy(\.isSane) else { return nil }
            matches += result.games.filter { $0.package == package }
            if !result.more {
                guard Set(matches.map(\.appId)).count == 1, let game = matches.first,
                      matches.allSatisfy({ $0 == game }) else { return nil }
                let identity = Self(title: game.title, package: package, appID: game.appId,
                    source: "https://avpplay.martek.de/api/v1/games/" + game.appId,
                    catalogStatus: game.status)
                return identity.isValid ? identity : nil
            }
        }
        return nil
    }
}
