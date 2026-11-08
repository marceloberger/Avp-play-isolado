import Foundation

/// Auditable mirror of the pinned 824 resolver, not a claim of runtime compatibility.
public enum Klepton824RecipeRules {
    public static let version = "824-a61188d"
    public static let revision = "recipes169-v1"
    public static func engineName(_ engine: LocalGenericEngine) -> String {
        switch engine {
        case .unreal4, .unreal: return "ue4"
        case .nativeActivity: return "native"
        default: return engine.rawValue
        }
    }
    public static func obbOverride(target: String?, package: String) -> String? {
        struct Contract: Decodable { let version: String; let genericOBB: [String: String] }
        guard let target, let url = Bundle.module.url(forResource: "klepton824-recipe-rules169", withExtension: "json"),
              let data = try? Data(contentsOf: url), let contract = try? JSONDecoder().decode(Contract.self, from: data),
              contract.version == version, let path = contract.genericOBB[target],
              path == "Android/obb/" + package else { return nil }
        return "android-files/" + path
    }
    /// Only explicit filenames constitute a required-file decision. Storage paths alone are risks.
    public static func obbNames(in references: [String]) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"(?i)([A-Za-z0-9._-]+\.obb)\b"#)
        return Set(references.flatMap { text in
            regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
                Range($0.range(at: 1), in: text).map { String(text[$0]) }
            }
        }).sorted()
    }
}

public struct RecipeDiagnostic169: Codable, Sendable, Equatable, Identifiable {
    public enum Severity: String, Codable, Sendable { case error, warning, information }
    public let code: String
    public let severity: Severity
    public let stage: String
    public let component: String
    public let file: String?
    public let message: String
    public let remedy: String
    public var id: String { code + ":" + (file ?? "") }
}

public struct RecipeDecision169: Codable, Sendable, Equatable {
    public let field: String
    public let value: String?
    /// observed, inferred or unknown; observed does not mean publisher authenticated.
    public let evidence: String
    public let source: String
}

public struct LocalRecipeAnalysis169: Codable, Sendable, Equatable {
    public let rules: String
    public let decisions: [RecipeDecision169]
    public let diagnostics: [RecipeDiagnostic169]
    public var canReviewForPrepare: Bool { !diagnostics.contains { $0.severity == .error } }

    public static func inspect(_ apk: ApkUnpacker.Inspection) -> Self {
        let analysis = LocalGenericTargetAnalysis.inspect(apk)
        let identity = apk.package.flatMap { AutomaticAPKIdentity.resolve(package: $0) }
        var decisions: [RecipeDecision169] = [
            .init(field: "package", value: apk.package, evidence: apk.package == nil ? "unknown" : "observed", source: "AndroidManifest.xml"),
            .init(field: "versionCode", value: apk.versionCode, evidence: apk.versionCode == nil ? "unknown" : "observed", source: "AndroidManifest.xml"),
            .init(field: "versionName", value: apk.versionName, evidence: apk.versionName == nil ? "unknown" : "observed", source: "AndroidManifest.xml"),
            .init(field: "appID", value: identity?.appID, evidence: identity == nil ? "unknown" : "observed", source: identity?.source ?? "Sem vínculo confiável; revisão manual necessária"),
            .init(field: "engine", value: analysis.engine?.rawValue, evidence: analysis.engine == nil ? "unknown" : "inferred", source: "Klepton 850 cc2856c: nomes das bibliotecas ARM64"),
            .init(field: "entrypoint", value: analysis.entrypoint, evidence: analysis.entrypoint == nil ? "unknown" : "inferred", source: "Resolver 850 e metadado NativeActivity; presença da biblioteca conferida"),
            .init(field: "target", value: identity.map { "x" + $0.appID }, evidence: identity == nil ? "unknown" : "inferred", source: "Target genérico experimental; nunca promoção a verified")
        ]
        decisions.append(.init(field: "architectures", value: apk.architectures.sorted().joined(separator: ", "), evidence: "observed", source: "Índice lib/ do APK"))
        decisions.append(.init(field: "nativeLibraries", value: apk.nativeLibraries.joined(separator: ", "), evidence: "observed", source: "Índice do APK; presença não comprova ABI ELF interna"))
        decisions.append(.init(field: "assets", value: apk.assets.joined(separator: ", "), evidence: "observed", source: "Índice assets/ do APK; inventário externo desconhecido"))
        decisions.append(.init(field: "dependencies", value: apk.declaredLibraries.joined(separator: ", "), evidence: "observed", source: "uses-library do manifesto; não é fechamento ELF/JNI"))
        var diagnostics = analysis.blockers.enumerated().map { index, message in
            RecipeDiagnostic169(code: "apk-\(index)", severity: .error, stage: "identificação", component: "APK", file: "AndroidManifest.xml / lib/arm64-v8a", message: message, remedy: "Revisar o APK e o entrypoint antes de gerar uma receita.")
        }
        if apk.splitName != nil {
            diagnostics.append(.init(code: "split-apk", severity: .error, stage: "identificação", component: "APK", file: apk.splitName, message: "APK split isolado; o conjunto base e suas dependências não foi comprovado.", remedy: "Selecionar um APK base completo; não concatenar splits."))
        }
        diagnostics.append(.init(code: "dependency-closure", severity: .warning, stage: "compatibilidade", component: "conversor", file: nil, message: "O inventário de bibliotecas não comprova dependências ELF, JNI e extensões gráficas suportadas.", remedy: "Revisar dependências específicas; não bloquear somente por esta incerteza."))
        if apk.nativeLibraries.contains(where: { $0.lowercased().contains("ssl") || $0.lowercased().contains("crypto") }) {
            diagnostics.append(.init(code: "tls-risk", severity: .warning, stage: "compatibilidade", component: "conversor", file: apk.nativeLibraries.filter { $0.lowercased().contains("ssl") || $0.lowercased().contains("crypto") }.joined(separator: ", "), message: "Bibliotecas TLS/crypto observadas; nomes não demonstram falha TLS.", remedy: "Preservar overlay TLS 168 e revisar logs de tradução; funcionamento ainda não confirmado."))
        }
        if identity == nil {
            diagnostics.append(.init(code: "identity-review", severity: .warning, stage: "receita", component: "receita", file: nil, message: "AppID desconhecido; análise disponível, geração executável exige procedência manual.", remedy: "Informar AppID real e fonte confiável no editor experimental."))
        }
        return .init(rules: ExperimentalRuntime183.klepton850.rules, decisions: decisions, diagnostics: diagnostics)
    }
}

public extension LocalProvisionalRecipe {
    var analysis169: LocalRecipeAnalysis169 {
        let base = LocalRecipeAnalysis169.inspect(.init(package: package, versionCode: versionCode, versionName: versionName,
            architectures: Set(architectures), files: assets.count + nativeLibraries.count, assets: assets,
            nativeLibraries: nativeLibraries, hasNativeActivity: hasNativeActivity == true,
            nativeActivityLibrary: nativeActivityLibrary, declaredLibraries: declaredLibraries ?? [], splitName: splitName))
        var decisions = base.decisions
        if let target = experimentalTarget {
            decisions.removeAll { $0.field == "appID" || $0.field == "target" }
            decisions += [.init(field: "appID", value: target.appID, evidence: automaticIdentity == nil ? "declared" : "observed", source: target.provenance),
                .init(field: "target", value: target.target, evidence: "inferred", source: target.toolchain + "; experimental")]
        }
        for file in externalFiles {
            decisions.append(.init(field: "externalFile:" + file.fileName, value: file.sha256, evidence: file.validationStatus == "sha256-verified" ? "observed" : "unknown", source: "SHA-256 local; " + (file.mappingEvidence ?? "mapeamento pendente")))
        }
        return .init(rules: base.rules, decisions: decisions, diagnostics: base.diagnostics + contentDiagnostics169)
    }

    var contentDiagnostics169: [RecipeDiagnostic169] {
        let associated = Set(externalFiles.map { $0.fileName.lowercased() })
        let names = Klepton850RecipeRules.obbNames(in: externalFileReferences)
        var result = names.filter { !associated.contains($0.lowercased()) }.map {
            RecipeDiagnostic169(code: "missing-obb", severity: .error, stage: "pré-Prepare", component: "assets", file: $0,
                message: "Referência explícita do manifesto sem OBB associado.", remedy: "Associar o arquivo correspondente e verificar SHA-256 e destino.")
        }
        if (!externalFileReferences.isEmpty && names.isEmpty) || automaticIdentity?.requiresExternalContent == true {
            result.append(.init(code: "external-inventory", severity: .warning, stage: "pré-Prepare", component: "assets", file: nil,
                message: "Há indícios de conteúdo externo; o inventário obrigatório completo é desconhecido.", remedy: "Revisar manualmente OBBs e assets. A heurística não comprova arquivo ausente nem autoriza declarar conteúdo completo."))
        }
        return result
    }
}

/// Pure review: previous versions provide suggestions, never executable configuration inheritance.
public struct RecipeSelection169: Sendable {
    public let compatible: [Recipe]
    public let previousVersions: [Recipe]
    public let diagnostics: [RecipeDiagnostic169]

    public static func inspect(_ apk: ApkUnpacker.Inspection, recipes: [Recipe]) -> Self {
        let samePackage = recipes.filter { $0.package == apk.package && $0.files.contains { $0.role == "apk" } }
        let compatible = samePackage.filter { String($0.versionCode) == apk.versionCode }
        let previous = samePackage.filter { String($0.versionCode) != apk.versionCode }
        var diagnostics: [RecipeDiagnostic169] = []
        if compatible.count > 1 {
            diagnostics.append(.init(code: "ambiguous-recipe", severity: .warning, stage: "seleção", component: "receita", file: nil,
                message: "Mais de uma receita tem package e versionCode compatíveis; hash ou seleção manual deve resolver.", remedy: "Usar a seleção por hash existente; nunca escolher pela ordem dos arquivos."))
        }
        if !previous.isEmpty {
            diagnostics.append(.init(code: "previous-version", severity: .information, stage: "seleção", component: "receita", file: nil,
                message: "Receitas de outras versões preservadas: " + previous.map { $0.id + " / " + String($0.versionCode) }.sorted().joined(separator: ", "),
                remedy: "Revisar configurações como referência; não herdar hashes, IDs de assets, dependências ou perfil de mods sem evidência da versão atual."))
        }
        return .init(compatible: compatible, previousVersions: previous, diagnostics: diagnostics)
    }
}

/// A review receipt can be reused only for the same bytes, recipe, rules and TLS overlay.
/// It does not authorize reusing a workspace or converted framework.
public struct AnalysisReuseKey169: Codable, Sendable, Equatable {
    public let apkSHA256: String
    public let recipeSHA256: String
    public let assetsSHA256: String
    public let identitySnapshotSHA256: String
    public let tlsOverlaySHA256: String
    public let rules: String
    public let toolchain: String

    public init(apkSHA256: String, recipe: Recipe, assets: [String: String],
                identitySnapshot: Data, tlsOverlay: Data) throws {
        let digests = [apkSHA256] + Array(assets.values)
        guard digests.allSatisfy({ $0.count == 64 && $0.allSatisfy(\.isHexDigit) }),
              assets.keys.allSatisfy(Recipe.isSafeRelativePath) else {
            throw RecipeError.invalid("Recibo de análise: hashes ou caminhos de assets inválidos.")
        }
        self.apkSHA256 = apkSHA256.lowercased()
        recipeSHA256 = try LocalAPKBuildEvidence.recipeHash(recipe)
        assetsSHA256 = try LocalAPKBuildEvidence.digest(assets.mapValues { $0.lowercased() })
        identitySnapshotSHA256 = Hashing.sha256(of: identitySnapshot)
        tlsOverlaySHA256 = Hashing.sha256(of: tlsOverlay)
        let profile = recipe.localExperimental.flatMap { ExperimentalRuntime183(rawValue: $0.toolchain) } ?? .klepton850
        rules = profile.rules
        toolchain = profile.rawValue
    }
}
