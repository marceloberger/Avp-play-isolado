import Foundation

typealias LocalOBBHashProgress = @Sendable (_ name: String, _ index: Int, _ count: Int,
                                           _ done: Int64, _ total: Int64, _ cached: Bool) -> Void

/// Observed APK facts remain a provisional record until a user supplies a documented AppID and a
/// locally validated generic target. Official and community recipes stay separate from this record.
public struct LocalProvisionalRecipe: Codable, Sendable, Equatable, Identifiable {
    public struct ExternalFile: Codable, Sendable, Equatable, Identifiable {
        public var path: String
        public var size: Int64
        /// Computed when the file is associated; old records without a digest remain explicitly unverified.
        public var sha256: String? = nil
        /// Classification and destination are set only when a generic target gives an unambiguous layout.
        public var kind: String? = nil
        public var destination: String? = nil
        public var package: String? = nil
        public var versionCode: String? = nil
        public var mappingEvidence: String? = nil
        public var validationStatus: String? = nil
        public var id: String { path }
    }

    public var id: String { "provisional-" + apkSHA256 }
    public let apkSHA256: String
    public let apkSize: Int64
    public let apkPath: String
    public let title: String
    public let package: String
    public let versionName: String?
    public let versionCode: String?
    public let architectures: [String]
    public let nativeLibraries: [String]
    public let assets: [String]
    public let externalFileReferences: [String]
    public var hasNativeActivity: Bool? = nil
    public var nativeActivityLibrary: String? = nil
    public var splitName: String? = nil
    public var declaredLibraries: [String]? = nil
    public var identification169: LocalRecipeAnalysis169? = nil
    public var externalFiles: [ExternalFile]
    public let createdAt: Date
    /// Catalog metadata is attached only after package/version matching; it is not an official recipe.
    public var communityTarget: CommunityKleptonTarget? = nil
    /// Explicit user-confirmed generic target; never inferred from the Android package name.
    public var experimentalTarget: LocalExperimentalTarget? = nil
    /// Editable declarations, not an executable recipe or a claim of verified identity.
    public struct ExperimentalDraft185: Codable, Sendable, Equatable {
        public var appID: String
        public var provenance: String
        public var runtime: String
    }
    public var onlineIdentity186: AutomaticAPKIdentity? = nil

    public var experimentalDraft185: ExperimentalDraft185? = nil

    public var experimentalReviewState185: String {
        if experimentalRecipe != nil { return "Receita revisada; elegibilidade de build depende da integridade e do registro do APK" }
        if experimentalDraft185 != nil || experimentalTarget != nil { return "Receita experimental salva · validação pendente" }
        return "Análise provisória salva"
    }


    public var genericAnalysis: LocalGenericTargetAnalysis {
        LocalGenericTargetAnalysis.analyze(package: package, versionCode: versionCode,
            architectures: Set(architectures), nativeLibraries: nativeLibraries,
            hasNativeActivity: hasNativeActivity == true, nativeActivityLibrary: nativeActivityLibrary)
    }

    public var experimentalRecipe: Recipe? {
        guard let target = experimentalTarget, let numericVersion = Int(versionCode ?? ""),
              experimentalBlockers.isEmpty else { return nil }
        let recipeID = Self.experimentalRecipeID(appID: target.appID, hash: apkSHA256)
        var metadata = LocalExperimentalRecipeMetadata(target: target, apkSHA256: apkSHA256,
            associatedFiles: externalFiles, package: package, versionCode: numericVersion, apkSize: apkSize,
            architectures: architectures, recipeID: recipeID)
        metadata.decisions169 = analysis169
        guard metadata.isValid else { return nil }
        let apkName = URL(fileURLWithPath: apkPath).lastPathComponent
        guard Recipe.isSafeName(apkName) else { return nil }
        return Recipe(schema: Recipe.supportedSchema, id: recipeID, title: title,
            package: package, versionName: versionName ?? "", versionCode: numericVersion,
            store: .init(appId: nil), toolchain: .init(target: target.target, minCommit: target.minCommit),
            files: [.init(name: apkName, role: "apk", id: "local-experimental", required: true, dest: "",
                          localName: "\(target.target).apk")], addons: nil,
            status: .init(playability: "untested", download: "local", notes: nil),
            icon: .init(steamAppId: nil, metaAppId: target.appID), trees: nil,
            localExperimental: metadata)
    }

    public var experimentalBlockers: [String] {
        guard let target = experimentalTarget else { return automaticTargetBlockers }
        var blockers: [String] = []
        if let draft = experimentalDraft185,
           draft.appID != target.appID || draft.provenance != target.provenance || draft.runtime != target.toolchain {
            blockers.append("Identidade ou perfil do rascunho ainda pendente de revisão")
        }
        if let profile = ExperimentalRuntime183(rawValue: target.toolchain) {
            if target.minCommit != profile.minCommit { blockers.append("Commit do target diverge do perfil experimental") }
        } else { blockers.append("Perfil experimental desconhecido") }
        blockers += (splitName == nil ? [] : ["APK split isolado; selecione um APK base completo."]) + genericAnalysis.blockers + (automaticIdentity == nil ? [] : automaticTargetBlockers)
        if target.target != "x\(target.appID)" || target.engine != genericAnalysis.engine
            || target.entrypoint != genericAnalysis.entrypoint {
            blockers.append("Dados do target experimental não correspondem à inspeção atual do APK")
        }
        blockers += contentDiagnostics169.filter { $0.severity == .error }.map {
            $0.message + " " + ($0.file ?? "") + " " + $0.remedy
        }
        for file in externalFiles where !file.isSafeForExperimentalRecipe {
            blockers.append("Arquivo externo sem classificação, destino ou SHA-256 validado: \(file.fileName)")
        }
        let destinations = externalFiles.compactMap { file in file.destination.map { $0.lowercased() + "/" + file.fileName.lowercased() } }
        if Set(destinations).count != destinations.count { blockers.append("Destinos externos duplicados; revisão necessária") }
        if let identity = automaticIdentity, identity.appID != target.appID { blockers.append("AppID manual diverge da identidade automática confirmada") }
        return blockers
    }

    public static func experimentalRecipeID(appID: String, hash: String) -> String {
        "experimental-\(appID)-\(String(hash.prefix(12)))"
    }

    public var communityTargetBlockers: [String] {
        guard let target = communityTarget else { return ["Nenhum target comunitário corresponde ao package ID e à versão observados"] }
        var result: [String] = []
        if package != target.packageID { result.append("Package ID diverge do registro comunitário") }
        if versionCode != target.versionCode { result.append("Version code diverge do registro comunitário") }
        if let versionName, versionName != target.versionName { result.append("Version name diverge da versão catalogada") }
        if !architectures.contains("arm64-v8a") { result.append("APK não comprova arquitetura arm64-v8a") }
        if !nativeLibraries.contains("lib/arm64-v8a/libUE4.so") { result.append("APK não contém libUE4.so; o target genérico não identificou a engine UE4") }
        return result
    }

    /// The generic Klepton row derives its entry library and OBB directory from the unpacked APK.
    /// An OBB is not a Prepare/Build prerequisite in Klepton; missing external files are surfaced as runtime/content uncertainty.
    public var genericTargetCanPrepareAndBuild: Bool { communityTarget != nil && communityTargetBlockers.isEmpty }

    /// A separate, derived local-only Recipe for the existing local import/Prepare/Build pipeline.
    /// It contains no asserted APK hash or official recipe provenance; registration verifies the selected APK.
    public var communityRecipe: Recipe? {
        guard genericTargetCanPrepareAndBuild, let target = communityTarget,
              let numericVersion = Int(versionCode ?? "") else { return nil }
        let apkName = URL(fileURLWithPath: apkPath).lastPathComponent
        guard Recipe.isSafeName(apkName), Recipe.isSafeName(target.target) else { return nil }
        return Recipe(schema: Recipe.supportedSchema, id: "community-\(target.appID)", title: target.title,
            package: package, versionName: versionName ?? "", versionCode: numericVersion,
            store: .init(appId: nil), toolchain: .init(target: target.target, minCommit: "a61188d"),
            files: [.init(name: apkName, role: "apk", id: "local-community", required: true, dest: "",
                          localName: "\(target.target).apk")], addons: nil,
            status: .init(playability: "untested", download: "local", notes: nil),
            icon: .init(steamAppId: nil, metaAppId: target.appID), trees: nil)
    }

    public var compatibilityBlockers: [String] {
        if experimentalTarget != nil { return experimentalBlockers }
        if communityTarget != nil { return communityTargetBlockers }
        var result: [String] = []
        result.append("Receita Klepton compatível e target verificados")
        result.append("Mapeamento de entrypoint e bibliotecas exigidas pela toolchain")
        if !architectures.contains("arm64-v8a") { result.append("APK com arquitetura arm64-v8a") }
        return result
    }
}

public struct LocalProvisionalRecipeStore: Sendable {
    public let root: URL
    public let hashCache: SHA256FileCache

    public init(root: URL) {
        self.root = root
        hashCache = SHA256FileCache(root: root.appendingPathComponent(".sha256-cache", isDirectory: true))
    }

    public func loadAll() throws -> [LocalProvisionalRecipe] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { try decoder.decode(LocalProvisionalRecipe.self, from: Data(contentsOf: $0)) }
    }

    /// Refreshes the saved record after the request; manual drafts/targets and assets are retained.
    public func resolveOnlineIdentity(for id: String,
        fetchPage: @Sendable (String, Int) async throws -> CatalogClient.Page = { query, page in
            try await CatalogClient().identityPage(package: query, page: page)
        }) async throws -> LocalProvisionalRecipe {
        guard id.hasPrefix("provisional-"), Recipe.isSafeName(id) else {
            throw LocalAPKVariantError.invalidRecord("Identificador provisório inválido")
        }
        let file = root.appendingPathComponent(id + ".json")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var record = try decoder.decode(LocalProvisionalRecipe.self, from: Data(contentsOf: file))
        if record.automaticIdentity != nil {
            let previous = record
            try activateAutomaticTarget(to: &record)
            if record != previous {
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(record).write(to: file, options: .atomic)
            }
            return record
        }
        let identity: AutomaticAPKIdentity?
        do {
            identity = try await AutomaticAPKIdentity.resolveWithOnlineFallback(package: record.package, fetchPage: fetchPage)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return record // Network failure leaves analysis and manual review available.
        }
        try Task.checkCancellation()
        guard let identity else { return record }
        record = try decoder.decode(LocalProvisionalRecipe.self, from: Data(contentsOf: file))
        guard record.package == identity.package, record.automaticIdentity == nil else { return record }
        record.onlineIdentity186 = identity
        try activateAutomaticTarget(to: &record)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: file, options: .atomic)
        return record
    }

    public func associate(_ urls: [URL], with id: String) throws -> LocalProvisionalRecipe {
        let file = root.appendingPathComponent(id + ".json")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var record = try decoder.decode(LocalProvisionalRecipe.self, from: Data(contentsOf: file))
        var entries = record.externalFiles
        for url in urls {
            guard let size = ContentStore.fileSize(url), size > 0 else { throw LocalAPKVariantError.missing(url.path) }
            let path = url.resolvingSymlinksInPath().path
            if !entries.contains(where: { $0.path == path }) {
                let digest = try hashCache.digest(url).lowercased()
                entries.append(.init(path: path, size: size, sha256: digest))
            } else if let index = entries.firstIndex(where: { $0.path == path }), entries[index].sha256 == nil {
                entries[index].sha256 = try hashCache.digest(url).lowercased()
            }
        }
        let previous = record
        record.externalFiles = entries
        entries = entries.map { entry in
            guard entry.kind == nil else { return entry }
            return Self.describeExternalFile(path: entry.path, size: entry.size, sha256: entry.sha256, record: record)
        }
        record.externalFiles = entries
        try activateAutomaticTarget(to: &record)
        guard record != previous else { return record }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: file, options: .atomic)
        return record
    }

    public func setExperimentalTarget(appID: String, provenance: String, runtime: ExperimentalRuntime183 = .klepton850, for id: String) throws -> LocalProvisionalRecipe {
        let file = root.appendingPathComponent(id + ".json")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var record = try decoder.decode(LocalProvisionalRecipe.self, from: Data(contentsOf: file))
        let analysis = record.genericAnalysis
        let target = try LocalExperimentalTarget(appID: appID, provenance: provenance, analysis: analysis, runtime: runtime)
        Self.applyExperimentalTarget(target, to: &record)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: file, options: .atomic)
        return record
    }

    private static func applyExperimentalTarget(_ target: LocalExperimentalTarget, to record: inout LocalProvisionalRecipe) {
        record.experimentalTarget = target
        record.externalFiles = record.externalFiles.map {
            if $0.isSafeForExperimentalRecipe, $0.package == record.package, $0.versionCode == record.versionCode {
                return $0
            }
            return Self.describeExternalFile(path: $0.path, size: $0.size, sha256: $0.sha256, record: record)
        }
    }

    /// Never overwrite a manual declaration. Eligibility remains governed by experimentalBlockers.
    private func activateAutomaticTarget(to record: inout LocalProvisionalRecipe) throws {
        guard record.communityTarget == nil, record.experimentalDraft185 == nil,
              record.experimentalTarget == nil, record.splitName == nil,
              record.automaticTargetBlockers.isEmpty, let identity = record.automaticIdentity else { return }
        let apk = URL(fileURLWithPath: record.apkPath)
        guard ContentStore.fileSize(apk) == record.apkSize,
              try hashCache.digest(apk, forceFull: true).lowercased() == record.apkSHA256 else { return }
        let target = try LocalExperimentalTarget(appID: identity.appID, provenance: identity.source, analysis: record.genericAnalysis)
        Self.applyExperimentalTarget(target, to: &record)
    }

    /// Saving declarations is independent of runtime availability and build eligibility.
    /// Unknown/partial fields are retained; no executable recipe is produced without the existing blockers passing.
    public func saveExperimentalDraft(appID: String, provenance: String,
                                      runtime: ExperimentalRuntime183 = .klepton850, for id: String) throws -> LocalProvisionalRecipe {
        try runtime.requirePermitted()
        let appID = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        let provenance = provenance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard appID.count <= 64, provenance.count <= 500,
              !(appID + provenance).unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw LocalAPKVariantError.invalidRecord("Campos do rascunho excedem os limites ou contêm caracteres de controle.")
        }
        let file = root.appendingPathComponent(id + ".json")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var record = try decoder.decode(LocalProvisionalRecipe.self, from: Data(contentsOf: file))
        let previous = record
        record.experimentalDraft185 = .init(appID: appID, provenance: provenance, runtime: runtime.rawValue)
        if let target = try? LocalExperimentalTarget(appID: appID, provenance: provenance,
                                                    analysis: record.genericAnalysis, runtime: runtime) {
            Self.applyExperimentalTarget(target, to: &record)
        }
        guard record != previous else { return record }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: file, options: .atomic)
        return record
    }

    public func mapExternalFile(_ path: String, kind: String, destination: String,
                                evidence: String, for id: String) throws -> LocalProvisionalRecipe {
        let file = root.appendingPathComponent(id + ".json")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var record = try decoder.decode(LocalProvisionalRecipe.self, from: Data(contentsOf: file))
        guard let index = record.externalFiles.firstIndex(where: { $0.path == path }),
              let target = record.experimentalTarget else {
            throw LocalAPKVariantError.invalidRecord("Selecione um arquivo associado e defina primeiro o target experimental.")
        }
        let cleanDestination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanEvidence = evidence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ["obb", "asset", "other"].contains(kind), Recipe.isSafeRelativePath(cleanDestination),
              !cleanEvidence.isEmpty, cleanEvidence.count <= 500,
              !cleanEvidence.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw LocalAPKVariantError.invalidRecord("Tipo, destino ou evidência de mapeamento inválidos.")
        }
        let external = record.externalFiles[index]
        if kind == "obb" {
            guard external.fileName.lowercased().hasSuffix(".obb") else {
                throw LocalAPKVariantError.invalidRecord("Um arquivo classificado como OBB precisa terminar em .obb.")
            }
            guard let expected = record.genericOBBDirectory else {
                throw LocalAPKVariantError.invalidRecord("Runtime selecionado sem layout externo conhecido para este target.")
            }
            guard cleanDestination == expected else {
                throw LocalAPKVariantError.invalidRecord("Destino OBB não corresponde ao layout genérico conhecido para \(target.engine.rawValue): \(expected).")
            }
        } else {
            guard cleanDestination.hasPrefix("android-files/") else {
                throw LocalAPKVariantError.invalidRecord("O destino externo deve ficar dentro de android-files/.")
            }
        }
        let source = URL(fileURLWithPath: external.path)
        guard source.path.hasPrefix("/"), source.standardizedFileURL.path == source.path,
              source.resolvingSymlinksInPath().standardizedFileURL.path == source.standardizedFileURL.path,
              let values = try? source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              FileManager.default.fileExists(atPath: source.path),
              let size = ContentStore.fileSize(source), size == external.size else {
            throw LocalAPKVariantError.invalidRecord("O arquivo mudou ou não está acessível; reassocie-o para recalcular tamanho e hash.")
        }
        let digest = try hashCache.digest(source).lowercased()
        record.externalFiles[index].sha256 = digest
        record.externalFiles[index].kind = kind
        record.externalFiles[index].destination = cleanDestination
        record.externalFiles[index].package = record.package
        record.externalFiles[index].versionCode = record.versionCode
        record.externalFiles[index].mappingEvidence = cleanEvidence
        record.externalFiles[index].validationStatus = "sha256-verified"
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: file, options: .atomic)
        return record
    }

    private static func describeExternalFile(path: String, size: Int64, sha256: String?, record: LocalProvisionalRecipe) -> LocalProvisionalRecipe.ExternalFile {
        let name = URL(fileURLWithPath: path).lastPathComponent
        guard record.externalFiles.filter({ $0.fileName.lowercased() == name.lowercased() }).count <= 1,
              let target = record.experimentalTarget else {
            return LocalProvisionalRecipe.ExternalFile(path: path, size: size, sha256: sha256)
        }
        let files = record.externalFiles.map { URL(fileURLWithPath: $0.path) }
        let destinations = LocalGameImport.automaticRuntimeDestinations(files: files,
            package: record.package, versionCode: record.versionCode ?? "", target: target.target, engine: record.genericAnalysis.engine)
        guard let directory = destinations[path], let sha256 else {
            return LocalProvisionalRecipe.ExternalFile(path: path, size: size, sha256: sha256)
        }
        return LocalProvisionalRecipe.ExternalFile(path: path, size: size, sha256: sha256,
                            kind: name.lowercased().hasSuffix(".obb") ? "obb" : "asset", destination: directory,
                            package: record.package, versionCode: record.versionCode,
                            mappingEvidence: "Klepton 850 cc2856c exact OBB / co-located payload layout for \(target.engine.rawValue)",
                            validationStatus: "sha256-verified")
    }

    /// Validates and turns user-associated OBBs into transfer entries for this exact local community variant.
    /// Official recipes and non-community local variants never consume this sidecar metadata.
    func installationOBBs(variant: LocalAPKVariant, recipe: Recipe,
                          obbDirectory: String?, report: @Sendable (String) -> Void = { _ in },
                          progress: LocalOBBHashProgress = { _, _, _, _, _, _ in }) throws -> [InstallationContent.Entry] {
        let localAPK = recipe.files.first { $0.role == "apk" }
        let isCommunity = localAPK?.id == "local-community" && recipe.id.hasPrefix("community-")
        guard isCommunity, variant.recipeID == recipe.id,
              variant.source == "local", variant.official == false,
              variant.recipeVersionCode == recipe.versionCode else { return [] }
        guard variant.sha256.count == 64, variant.sha256.allSatisfy({ $0.isHexDigit }),
              Recipe.isSafeName(recipe.package), Recipe.isSafeName(recipe.toolchain.target) else {
            throw LocalAPKVariantError.invalidRecord("Identidade da variante comunitária inválida para validar OBBs.")
        }

        let recordURL = root.appendingPathComponent("provisional-\(variant.sha256.lowercased()).json")
        guard FileManager.default.fileExists(atPath: recordURL.path) else {
            throw LocalAPKVariantError.missing(recordURL.path)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(LocalProvisionalRecipe.self, from: Data(contentsOf: recordURL))
        guard record.id == "provisional-\(variant.sha256.lowercased())",
              record.apkSHA256.lowercased() == variant.sha256.lowercased(),
              record.apkSize == variant.size,
              record.package == recipe.package, record.package == variant.package,
              record.versionCode == String(recipe.versionCode), record.versionCode == variant.versionCode,
              record.versionName == variant.versionName,
              variant.originalAPKSourcePath == nil || variant.originalAPKSourcePath == record.apkPath,
              Self.provisionalRecord(record, matches: recipe) else {
            throw LocalAPKVariantError.invalidRecord("A receita provisória, o APK e a variante local não correspondem; os OBBs não serão preparados para staging.")
        }
        guard !record.externalFiles.isEmpty else { return [] }
        let expectedDirectory = "android-files/Android/obb/\(recipe.package)"
        guard obbDirectory == expectedDirectory, Recipe.isSafeRelativePath(expectedDirectory) else {
            throw LocalAPKVariantError.invalidRecord("A toolchain não confirmou o diretório Android/obb do pacote; staging dos OBBs bloqueado.")
        }

        var seen = Set<String>()
        var result: [InstallationContent.Entry] = []
        for (index, external) in record.externalFiles.enumerated() {
            guard external.path.hasPrefix("/"),
                  URL(fileURLWithPath: external.path).standardizedFileURL.path == external.path,
                  Recipe.isSafeName(URL(fileURLWithPath: external.path).lastPathComponent),
                  URL(fileURLWithPath: external.path).pathExtension.lowercased() == "obb",
                  external.size > 0 else {
                throw LocalAPKVariantError.unsafePath(external.path)
            }
            let source = URL(fileURLWithPath: external.path)
            let name = source.lastPathComponent
            guard let expectedHash = external.sha256?.lowercased(), expectedHash.count == 64,
                  expectedHash.allSatisfy({ $0.isHexDigit }) else {
                throw LocalAPKVariantError.invalidRecord("O OBB '\(name)' não tem um SHA-256 registrado; staging bloqueado.")
            }
            guard seen.insert(name.lowercased()).inserted else {
                throw LocalAPKVariantError.invalidRecord("Há nomes OBB duplicados; os arquivos não podem ser mapeados sem ambiguidade: \(name)")
            }
            guard FileManager.default.fileExists(atPath: source.path) else {
                throw DeviceError.tool("OBB associado ausente: \(name) (\(source.path)).")
            }
            guard source.resolvingSymlinksInPath().standardizedFileURL.path == source.standardizedFileURL.path,
                  let values = try? source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else {
                throw DeviceError.tool("O caminho do OBB associado é inseguro ou não é um arquivo regular: \(source.path).")
            }
            guard let actualSize = ContentStore.fileSize(source) else {
                throw DeviceError.tool("OBB associado ausente ou ilegível: \(name).")
            }
            guard actualSize == external.size else {
                throw DeviceError.tool("Tamanho do OBB \(name) mudou (registrado \(external.size), atual \(actualSize)); staging bloqueado.")
            }
            report("Validando SHA-256 do OBB \(name)…")
            let actualHash = try hashCache.digest(source, log: report) { done, total, cached in
                progress(name, index + 1, record.externalFiles.count, done, total, cached)
            }.lowercased()
            guard actualHash == expectedHash else {
                throw DeviceError.tool("SHA-256 do OBB \(name) diverge do valor registrado; staging bloqueado.")
            }
            let destination = "Documents/\(expectedDirectory)/\(name)"
            result.append(InstallationContent.Entry(source: source, destination: destination,
                                                     size: actualSize, sha256: actualHash))
        }
        return result.sorted { $0.destination < $1.destination }
    }

    func installationExperimentalFiles(variant: LocalAPKVariant, recipe: Recipe,
                                       obbDirectory: String?, report: @Sendable (String) -> Void = { _ in }) throws -> [InstallationContent.Entry] {
        guard let metadata = recipe.localExperimental, metadata.isValid,
              recipe.files.contains(where: { $0.role == "apk" && $0.id == "local-experimental" }),
              variant.recipeID == recipe.id, variant.source == "local", !variant.official,
              variant.recipeVersionCode == recipe.versionCode,
              variant.sha256.lowercased() == metadata.apkSHA256 else { return [] }
        let recordURL = root.appendingPathComponent("provisional-\(variant.sha256.lowercased()).json")
        guard FileManager.default.fileExists(atPath: recordURL.path) else { throw LocalAPKVariantError.missing(recordURL.path) }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(LocalProvisionalRecipe.self, from: Data(contentsOf: recordURL))
        guard record.apkSHA256.lowercased() == metadata.apkSHA256,
              record.apkSize == variant.size, record.package == recipe.package,
              record.versionCode == String(recipe.versionCode), record.experimentalTarget?.target == recipe.toolchain.target,
              record.experimentalTarget?.provenance == metadata.appIDProvenance,
              record.externalFiles == metadata.associatedFiles,
              record.experimentalBlockers.isEmpty else {
            throw LocalAPKVariantError.invalidRecord("Metadados experimentais e associação local divergiram; arquivos externos bloqueados.")
        }
        var seen = Set<String>()
        var destinations = Set<String>()
        var result: [InstallationContent.Entry] = []
        for external in record.externalFiles {
            guard external.isSafeForExperimentalRecipe,
                  let kind = external.kind, let directory = external.destination else {
                throw LocalAPKVariantError.invalidRecord("Arquivo externo sem tipo, destino, evidência ou hash validado.")
            }
            if kind == "obb", obbDirectory != directory {
                throw LocalAPKVariantError.invalidRecord("Destino OBB informado diverge do destino do runtime selecionado.")
            }
            let source = URL(fileURLWithPath: external.path)
            let name = source.lastPathComponent
            let collisionKey = kind == "obb" ? name.lowercased() : "\(directory)/\(name)".lowercased()
            guard seen.insert(collisionKey).inserted else {
                throw LocalAPKVariantError.invalidRecord("Arquivos externos com nome duplicado não podem ser mapeados com segurança: \(name)")
            }
            guard FileManager.default.fileExists(atPath: source.path),
                  source.resolvingSymlinksInPath().standardizedFileURL.path == source.standardizedFileURL.path,
                  let values = try? source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  ContentStore.fileSize(source) == external.size,
                  destinations.insert("Documents/\(directory)/\(name)").inserted else {
                throw LocalAPKVariantError.invalidRecord("Arquivo externo ausente, alterado, duplicado ou com caminho inseguro: \(name)")
            }
            report("Validando SHA-256 do arquivo experimental \(name)…")
            let digest = try hashCache.digest(source).lowercased()
            guard digest == external.sha256?.lowercased() else {
                throw LocalAPKVariantError.hashMismatch(expected: external.sha256 ?? "", actual: digest)
            }
            result.append(.init(source: source, destination: "Documents/\(directory)/\(name)",
                                size: external.size, sha256: digest))
        }
        return result.sorted { $0.destination < $1.destination }
    }

    private static func provisionalRecord(_ record: LocalProvisionalRecipe, matches recipe: Recipe) -> Bool {
        if let target = record.communityTarget, recipe.id == "community-\(target.appID)" {
            return target.target == recipe.toolchain.target && target.packageID == recipe.package
                && target.versionCode == String(recipe.versionCode) && target.versionName == recipe.versionName
        }
        guard let target = record.experimentalTarget, let metadata = recipe.localExperimental else { return false }
        return recipe.id == metadata.recipeID && metadata.apkSHA256 == record.apkSHA256
            && metadata.appID == target.appID && metadata.target == target.target
            && metadata.package == record.package && metadata.versionCode == Int(record.versionCode ?? "")
            && target.target == recipe.toolchain.target
    }

    /// Inspects the APK archive index and manifest, then hashes the selected APK once through the shared cache.
    /// No APK, OBB, or other external source is modified or copied.
    public func create(from apk: URL, externalFiles: [URL] = [],
                       progress: @Sendable (LocalImportProgress) -> Void = { _ in }) throws -> LocalProvisionalRecipe {
        let inspection = try ApkUnpacker().inspect(apk: apk)
        guard let package = inspection.package, !package.isEmpty else {
            throw LocalAPKVariantError.invalidRecord("O APK não contém um Package ID verificável.")
        }
        let size = ContentStore.fileSize(apk) ?? 0
        guard size > 0 else { throw LocalAPKVariantError.missing(apk.path) }
        let digest = try hashCache.digest(apk, progress: { done, total, _ in
            progress(LocalImportProgress(phase: "Verificando APK para receita provisória", done: done, total: total))
        }).lowercased()
        let label = inspection.applicationLabel.flatMap { value -> String? in
            guard !value.hasPrefix("@"), !value.hasPrefix("?"), !value.isEmpty else { return nil }
            return value
        }
        var record = LocalProvisionalRecipe(apkSHA256: digest, apkSize: size, apkPath: apk.resolvingSymlinksInPath().path,
            title: label ?? AutomaticAPKIdentity.resolve(package: package)?.title ?? package, package: package, versionName: inspection.versionName,
            versionCode: inspection.versionCode, architectures: inspection.architectures.sorted(),
            nativeLibraries: inspection.nativeLibraries, assets: inspection.assets,
            externalFileReferences: inspection.externalFileReferences,
            hasNativeActivity: inspection.hasNativeActivity,
            nativeActivityLibrary: inspection.nativeActivityLibrary,
            externalFiles: try externalFiles.map { url in
                guard let fileSize = ContentStore.fileSize(url), fileSize > 0 else {
                    throw LocalAPKVariantError.missing(url.path)
                }
                return .init(path: url.resolvingSymlinksInPath().path, size: fileSize, sha256: try hashCache.digest(url).lowercased())
            }, createdAt: Date(), communityTarget: CommunityKleptonTarget.candidate(
                package: package, versionCode: inspection.versionCode, versionName: inspection.versionName))
        record.splitName = inspection.splitName
        record.declaredLibraries = inspection.declaredLibraries
        record.identification169 = LocalRecipeAnalysis169.inspect(inspection)
        try activateAutomaticTarget(to: &record)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent(record.id + ".json")
        if FileManager.default.fileExists(atPath: destination.path) {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let existing = try decoder.decode(LocalProvisionalRecipe.self, from: Data(contentsOf: destination))
            guard existing.apkSHA256 == digest, existing.package == package else {
                throw LocalAPKVariantError.invalidRecord("Registro provisório conflitante para o APK.")
            }
            return existing
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: destination, options: .atomic)
        return record
    }

}
