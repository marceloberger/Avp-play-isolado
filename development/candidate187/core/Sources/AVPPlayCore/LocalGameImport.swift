import Foundation

/// Read-only discovery and registration of a game folder supplied by the user.
public struct LocalGameImport: Sendable {
    public struct AdditionalFileReview: Identifiable, Equatable, Sendable {
        public let id: String
        public let origin: String
        public let name: String
        public let size: Int64
        public let sha256: String
        public let classification: String
        public let suggestedDestination: String
    }

    public struct Discovery: Sendable {
        public let root: URL
        public let apk: URL?
        public let files: [String: URL]
        public let missingRequired: [String]
        public let unmatchedFiles: [URL]
        public let apkInspection: ApkUnpacker.Inspection?
        public let ignoredFiles: [URL]

        public var canInstall: Bool { apk != nil && missingRequired.isEmpty }
    }

    public init() {}

    public func uniqueAPK(in folder: URL) -> URL? {
        let candidates = Set(Adopter.index([folder], maxDepth: 32).values.flatMap { $0 }
            .filter { $0.pathExtension.lowercased() == "apk" })
        return candidates.count == 1 ? candidates.first : nil
    }

    public struct AutomaticSelection: Sendable {
        public let recipe: Recipe
        public let apk: URL
        public let sha256: String
        public let recognizedHash: Bool
    }

    /// Resolve identity first. Hash recognition selects among compatible recipes, never overrides compatibility.
    public func identify(_ source: URL, recipes: [Recipe], learning: LocalAPKLearningStore, progress: @Sendable (LocalImportProgress) -> Void = { _ in }) throws -> AutomaticSelection {
        try Task.checkCancellation()
        progress(LocalImportProgress(phase: "Identificando jogo"))
        let directory = (try source.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true
        let candidates = directory
            ? Array(Set(Adopter.index([source], maxDepth: 32).values.flatMap { $0 }.filter { $0.pathExtension.lowercased() == "apk" })).sorted { $0.path < $1.path }
            : [source]
        var selections: [AutomaticSelection] = []
        try Task.checkCancellation()
        for apk in candidates {
            try Task.checkCancellation()
            let inspection: ApkUnpacker.Inspection
            do { inspection = try ApkUnpacker().inspect(apk: apk) }
            catch { try Task.checkCancellation(); if !directory { throw error }; continue }
            let compatible = RecipeSelection169.inspect(inspection, recipes: recipes).compatible
            guard !compatible.isEmpty else { continue }
            let hash = try learningHash(apk, cache: LocalAPKVariantStore(root: learning.root.deletingLastPathComponent()).hashCache, progress: progress)
            var matches: [AutomaticSelection] = []
            for recipe in compatible {
                let locallyRecognized = try learning.load(recipe).current?.hashes[hash]
                let known = recipe.files.contains { $0.role == "apk" && $0.sha256?.lowercased() == hash }
                    || locallyRecognized == ContentStore.fileSize(apk)
                matches.append(AutomaticSelection(recipe: recipe, apk: apk, sha256: hash, recognizedHash: known))
            }
            let recognized = matches.filter(\.recognizedHash)
            selections += recognized.isEmpty ? matches : recognized
        }
        guard selections.count == 1, let selected = selections.first else {
            throw LocalAPKVariantError.invalidRecord(selections.isEmpty
                ? "Nenhuma receita compatível com o package ID e VersionCode. Selecione um APK compatível; nenhuma receita foi alterada."
                : "Há mais de um APK ou receita compatível. Selecione o APK individual ou use Configurações avançadas para escolher a receita.")
        }
        return selected
    }

    private func learningHash(_ apk: URL, cache: SHA256FileCache, progress: @Sendable (LocalImportProgress) -> Void) throws -> String {
        try cache.digest(apk, progress: { done, total, _ in
            progress(LocalImportProgress(phase: "Verificando APK", done: done, total: total))
        }).lowercased()
    }

    public func discover(in folder: URL, recipe: Recipe? = nil, additionalSources: [URL] = [], maxDepth: Int = 32,
                         selectedAPK: URL? = nil) throws -> Discovery {
        try Task.checkCancellation()
        let root = folder.resolvingSymlinksInPath().standardizedFileURL
        guard (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw LocalAPKVariantError.missing(root.path)
        }
        let extras = additionalSources.map(\.standardizedFileURL)
        let index = Adopter.index([root] + extras, maxDepth: maxDepth)
        try Task.checkCancellation()
        // No recipe: discover references for review, without inventing roles or destinations.
        guard let recipe else {
            let apks = Set(index.values.flatMap { $0 }.filter { $0.pathExtension.lowercased() == "apk" })
            guard apks.count == 1, let apk = apks.first else {
                throw LocalAPKVariantError.invalidRecord("Selecione um APK individual; a pasta não identifica um único APK para análise automática.")
            }
            let inspection = try ApkUnpacker().inspect(apk: apk)
            let external = Set(index.values.flatMap { $0 }).filter { $0 != apk }
            let ignored = external.filter { Self.isIgnored($0, relativeTo: root) }
            return Discovery(root: root, apk: apk, files: [:], missingRequired: ["Receita experimental validada"],
                unmatchedFiles: external.filter { !Self.isIgnored($0, relativeTo: root) }.sorted { $0.path < $1.path },
                apkInspection: inspection, ignoredFiles: ignored.sorted { $0.path < $1.path })
        }
        var matches: [String: URL] = [:]
        let recipeFiles = recipe.files + (recipe.addons?.items ?? []).map { $0.asFile(dest: recipe.addons?.dest) }
        for file in recipeFiles where file.role != "apk" {
            let candidates = (index[file.name] ?? []).uniqued(by: { $0.resolvingSymlinksInPath().path })
            if candidates.count <= 1 {
                if let candidate = candidates.first, try verified(candidate, for: file) { matches[file.name] = candidate }
                continue
            }
            // Only authoritative recipe facts can disambiguate external content. Directory order
            // is not evidence of identity; hashing reads the source without creating sidecars.
            var compatible = candidates.filter { candidate in
                file.size.map { ContentStore.fileSize(candidate) == $0 } ?? true
            }
            if let expectedHash = file.sha256 {
                compatible = try compatible.filter { candidate in
                    try Task.checkCancellation()
                    return try Hashing.sha256(of: candidate).lowercased() == expectedHash.lowercased()
                }
            }
            guard compatible.count == 1, let candidate = compatible.first else {
                throw LocalAPKVariantError.invalidRecord(
                    "Há arquivos duplicados para \(file.name); tamanho e SHA-256 da receita não identificam uma origem única. Selecione uma pasta que contenha apenas os arquivos desejados.")
            }
            matches[file.name] = candidate
        }

        let apkFile = recipe.files.first(where: { $0.role == "apk" })
        var discoveredAPK: URL?
        var selectedInspection: ApkUnpacker.Inspection?
        var unmatched = Set(index.values.flatMap { $0 })
        if let apkFile {
            let names = Set([apkFile.name, apkFile.localName ?? ""])
            let named = names.flatMap { index[$0] ?? [] }
            let allAPKs = index.values.flatMap { $0 }.filter { $0.pathExtension.lowercased() == "apk" }
            let candidates = (named + allAPKs).uniqued(by: \.standardizedFileURL.path).sorted { left, right in
                func rank(_ url: URL) -> (Int, Int, String) {
                    let isNamed = names.contains(url.lastPathComponent) ? 0 : 1
                    let isBase = url.lastPathComponent.lowercased() == "base.apk" ? 0 : 1
                    return (isNamed, isBase, url.path)
                }
                let a = rank(left), b = rank(right)
                if a.0 != b.0 { return a.0 < b.0 }
                if a.1 != b.1 { return a.1 < b.1 }
                return a.2 < b.2
            }
            for candidate in selectedAPK.map({ [$0] }) ?? candidates {
                try Task.checkCancellation()
                guard let inspection = try? ApkUnpacker().inspect(apk: candidate),
                      inspection.package == recipe.package,
                      inspection.architectures.contains("arm64-v8a") else { continue }
                discoveredAPK = candidate
                selectedInspection = inspection
                let selectedPath = candidate.resolvingSymlinksInPath().standardizedFileURL.path
                unmatched = Set(unmatched.filter { $0.resolvingSymlinksInPath().standardizedFileURL.path != selectedPath })
                break
            }
        }
        for url in matches.values { unmatched.remove(url) }
        let missing = recipeFiles.filter { $0.required && ($0.role == "apk" ? discoveredAPK == nil : matches[$0.name] == nil) }
            .map(\.name).sorted()
        let ignored = unmatched.filter { Self.isIgnored($0, relativeTo: root) }
        unmatched.subtract(ignored)
        return Discovery(root: root, apk: discoveredAPK, files: matches, missingRequired: missing,
                         unmatchedFiles: unmatched.sorted { $0.path < $1.path }, apkInspection: selectedInspection,
                         ignoredFiles: ignored.sorted { $0.path < $1.path })
    }

    /// Save/reuse an incomplete analysis. External bytes stay at their source; association
    /// uses the existing hash cache and canonical-path deduplication, never variant registration.
    public func createProvisionalAnalysis(from source: URL, knownRecipes: [Recipe] = [],
                                          store: LocalProvisionalRecipeStore,
                                          progress: @Sendable (LocalImportProgress) -> Void = { _ in }) throws -> LocalProvisionalRecipe {
        let directory = try source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        let found = directory ? try discover(in: source) : nil
        let apk = found?.apk ?? source
        let inspection = try found?.apkInspection ?? ApkUnpacker().inspect(apk: apk)
        if let existing = knownRecipes.first(where: {
            $0.package == inspection.package && String($0.versionCode) == inspection.versionCode
                && $0.files.contains(where: { $0.role == "apk" })
        }) {
            throw LocalAPKVariantError.invalidRecord("Já existe receita para este package ID e VersionCode: \(existing.title). A receita existente não foi alterada.")
        }
        let record = try store.create(from: apk, progress: progress)
        guard let found, !found.unmatchedFiles.isEmpty else { return record }
        progress(LocalImportProgress(phase: "Associando arquivos externos para revisão"))
        return try store.associate(found.unmatchedFiles, with: record.id)
    }

    private func verified(_ url: URL, for file: RecipeFile) throws -> Bool {
        if !file.required && file.sha256 == nil { return false }
        if file.required { return true } // Registration records recipe mismatches; install validation blocks them.
        guard file.size == nil || file.size == ContentStore.fileSize(url) else { return false }
        guard let hash = file.sha256 else { return true }
        return try Hashing.sha256(of: url).lowercased() == hash.lowercased()
    }

    public static func classification(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "obb": return "OBB"
        case "pak", "ucas", "utoc", "uasset", "uexp", "ubulk": return "Asset de jogo"
        case "lang", "locres", "po", "mo", "strings", "stringsdict": return "Localização"
        case "srt", "vtt", "ass", "ssa", "sub": return "Legenda"
        case "png", "jpg", "jpeg", "tga", "dds", "ktx", "webp": return "Textura/imagem"
        case "wav", "ogg", "mp3", "wem", "bnk": return "Áudio"
        case "apk": return "APK"
        default: return "Outro recurso"
        }
    }

    /// Build a review row from a discovered extra. Hashing is deliberately full and uncached so
    /// the value shown to the user is the same integrity value checked when they confirm it.
    public func reviewAdditionalFiles(_ files: [URL], recipe: Recipe) throws -> [AdditionalFileReview] {
        try files.sorted { $0.path < $1.path }.map { file in
            let url = file.resolvingSymlinksInPath().standardizedFileURL
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let size = ContentStore.fileSize(url) else {
                throw LocalAPKVariantError.missing("Arquivo adicional indisponível: \(url.path)")
            }
            return AdditionalFileReview(id: url.path, origin: url.path, name: url.lastPathComponent,
                size: size, sha256: try Hashing.sha256(of: url), classification: Self.classification(url),
                suggestedDestination: Self.suggestedAdditionalDestination(for: url, recipe: recipe))
        }
    }

    /// Reuse the recipe's OBB directory for extras when one exists; otherwise keep extras under
    /// the generic app data folder and let the reviewer choose another safe destination.
    public static func suggestedAdditionalDestination(for url: URL, recipe: Recipe) -> String {
        let files = recipe.files + (recipe.addons?.items ?? []).map { $0.asFile(dest: recipe.addons?.dest) }
        if let obb = files.first(where: { $0.role == "obb" || $0.name.lowercased().hasSuffix(".obb") }),
           let directory = StagePlan.directory(for: obb), directory.hasPrefix("Documents/") {
            return "\(directory.dropFirst("Documents/".count))/\(url.lastPathComponent)"
        }
        if classification(url) == "OBB" {
            return "android-files/Android/obb/\(recipe.package)/\(url.lastPathComponent)"
        }
        return "android-files/\(url.lastPathComponent)"
    }

    /// A runtime directory is evidence only for exact OBBs, or recognized payloads beside
    /// those OBBs / already inside that layout. Extension alone never selects a directory.
    static func automaticRuntimeDestinations(files: [URL], package: String, versionCode: String,
                                              target: String?, engine: LocalGenericEngine?) -> [String: String] {
        guard let directory = RecipeValidation176.obbDirectory(target: target, package: package, engine: engine, version: 850) else { return [:] }
        let groups = Dictionary(grouping: files, by: { $0.lastPathComponent.lowercased() })
        let obbNames = Set(["main.\(versionCode).\(package).obb", "patch.\(versionCode).\(package).obb"])
        let obbs = files.filter { obbNames.contains($0.lastPathComponent) && groups[$0.lastPathComponent.lowercased()]?.count == 1 }
        let parents = Set(obbs.map { $0.deletingLastPathComponent().path })
        let classes: Set<String> = ["Asset de jogo", "Localização", "Legenda", "Textura/imagem", "Áudio"]
        var result: [String: String] = [:]
        for file in files {
            guard Recipe.isSafeName(file.lastPathComponent), groups[file.lastPathComponent.lowercased()]?.count == 1,
                  !isIgnored(file, relativeTo: file.deletingLastPathComponent()) else { continue }
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
            let inLayout = file.deletingLastPathComponent().path.hasSuffix("/" + String(directory.dropFirst("android-files/".count)))
            if obbNames.contains(file.lastPathComponent) || (classes.contains(classification(file)) && (parents.contains(file.deletingLastPathComponent().path) || inLayout)) {
                result[file.resolvingSymlinksInPath().path] = directory
            }
        }
        return result
    }

    /// Automatically include only recognized game payloads whose destination is evidenced by the
    /// recipe's OBB or single shared asset directory. Unknown types and ambiguous recipes stay pending.
    public func automaticAdditionalDestinations(for discovery: Discovery, recipe: Recipe) -> [String: String] {
        let recipeFiles = recipe.files + (recipe.addons?.items ?? []).map { $0.asFile(dest: recipe.addons?.dest) }
        let assetDirectories = Set(recipeFiles.filter { $0.role != "apk" }
            .compactMap(StagePlan.directory(for:)).filter { $0.hasPrefix("Documents/") }
            .map { String($0.dropFirst("Documents/".count)) })
        let destinationDirectory: String?
        if assetDirectories.count == 1 { destinationDirectory = assetDirectories.first }
        else { destinationDirectory = nil }
        let metadata = recipe.localExperimental
        let runtime = metadata.map { Self.automaticRuntimeDestinations(files: discovery.unmatchedFiles,
            package: recipe.package, versionCode: String(recipe.versionCode), target: recipe.toolchain.target, engine: $0.engine) } ?? [:]
        let known = Set(recipeFiles.map(\.name) + recipeFiles.compactMap(\.localName))
        let safeClasses: Set<String> = ["OBB", "Asset de jogo", "Localização", "Legenda", "Textura/imagem", "Áudio"]
        var destinations: [String: String] = [:]
        let groups = Dictionary(grouping: discovery.unmatchedFiles, by: { $0.lastPathComponent.lowercased() })
        for file in discovery.unmatchedFiles {
            let path = file.resolvingSymlinksInPath().path
            let bindings = metadata?.associatedFiles.filter { $0.path == path && $0.isSafeForExperimentalRecipe
                && $0.package == recipe.package && $0.versionCode == String(recipe.versionCode)
                && $0.size == ContentStore.fileSize(file) } ?? []
            let mapped = bindings.count == 1 ? bindings.first?.destination : nil
            if file.pathExtension.lowercased() == "obb", mapped == nil,
               !["main.\(recipe.versionCode).\(recipe.package).obb", "patch.\(recipe.versionCode).\(recipe.package).obb"].contains(file.lastPathComponent) { continue }
            // Conflicting recipe directories cannot be resolved by falling back to runtime layout.
            let directory = mapped ?? destinationDirectory ?? (assetDirectories.isEmpty ? runtime[path] : nil)
            guard let directory, groups[file.lastPathComponent.lowercased()]?.count == 1,
                  Recipe.isSafeName(file.lastPathComponent),
                  !known.contains(where: { $0.lowercased() == file.lastPathComponent.lowercased() }),
                  (mapped != nil || safeClasses.contains(Self.classification(file))),
                  !Self.isIgnored(file, relativeTo: discovery.root) else { continue }
            // Do not overwrite a declared asset path or another selected extra.
            let destination = "\(directory)/\(file.lastPathComponent)"
            guard !recipeFiles.contains(where: { StagePlan.destination(for: $0) == "Documents/\(destination)" }),
                  !destinations.values.contains(where: { $0.lowercased() == destination.lowercased() }), Self.safeAdditionalDestination(destination) else { continue }
            destinations[file.resolvingSymlinksInPath().standardizedFileURL.path] = destination
        }
        return destinations
    }

    private static func isIgnored(_ url: URL, relativeTo root: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        let ext = url.pathExtension.lowercased()
        let temporaryDirectory = Set(["cache", "caches", "saved", "savegames", "logs", "crashreports", "reports", "config", "configs", "tmp", "temp"])
        let prefix = root.standardizedFileURL.path + "/"
        let relative = url.standardizedFileURL.path.hasPrefix(prefix) ? String(url.standardizedFileURL.path.dropFirst(prefix.count)) : ""
        if relative.split(separator: "/").dropLast().contains(where: { temporaryDirectory.contains($0.lowercased()) }) { return true }
        return name.hasPrefix(".") || name == "thumbs.db" || name == "desktop.ini"
            || ["so", "sav", "log", "crash", "dmp", "tmp", "temp", "bak", "ini", "cfg", "conf"].contains(ext)
            || name == "androidmanifest.xml" || name == "apktool.yml"
            || name.contains("crashreport") || name.contains("errorreport") || name.contains("cache")
    }

    /// Copies discovered files into the app's isolated local-variants area. The source folder is only read.
    public func register(_ discovery: Discovery, recipe: Recipe,
                         store: LocalAPKVariantStore = LocalAPKVariantStore(),
                         additionalDestinations: [String: String] = [:],
                         expectedAdditionalHashes: [String: String] = [:],
                         automaticAdditionalPaths: Set<String> = [],
                         progress: @Sendable (LocalImportProgress) -> Void = { _ in }) throws -> LocalAPKVariant {
        guard let apk = discovery.apk else { throw LocalAPKVariantError.missing("APK for package \(recipe.package)") }
        try Task.checkCancellation()
        var assets: [LocalAPKAsset] = []
        let recipeFiles = recipe.files + (recipe.addons?.items ?? []).map { $0.asFile(dest: recipe.addons?.dest) }
        for file in recipeFiles where file.role != "apk" {
            guard let source = discovery.files[file.name] else { continue }
            let sourceSize = ContentStore.fileSize(source) ?? 0
            let hash = try store.hashCache.digest(source, progress: { done, total, _ in
                progress(LocalImportProgress(phase: "Verificando arquivos adicionais", done: done, total: total))
            }).lowercased()
            assets.append(LocalAPKAsset(name: file.name, sourcePath: source.standardizedFileURL.path,
                                        sourceRootPath: source.deletingLastPathComponent().standardizedFileURL.path,
                                        size: sourceSize, sha256: hash,
                                        recipeSizeMatches: file.size.map { $0 == sourceSize } ?? true,
                                        recipeHashMatches: file.sha256.map { $0.lowercased() == hash }))
        }
        let knownSources = Set(discovery.files.values.map { $0.resolvingSymlinksInPath().path })
        var selectedDestinations = Set<String>()
        for (path, destination) in additionalDestinations.sorted(by: { $0.key < $1.key }) {
            guard let source = discovery.unmatchedFiles.first(where: { $0.resolvingSymlinksInPath().path == URL(fileURLWithPath: path).resolvingSymlinksInPath().path }),
                  !knownSources.contains(source.resolvingSymlinksInPath().path), Self.safeAdditionalDestination(destination) else {
                throw LocalAPKVariantError.invalidRecord("Arquivo adicional sem seleção válida ou destino inseguro: \(path)")
            }
            let name = source.lastPathComponent
            guard !recipeFiles.contains(where: { $0.localName == name || $0.name == name }) else {
                throw LocalAPKVariantError.invalidRecord("O nome \(name) já pertence à receita; destino adicional recusado.")
            }
            let size = ContentStore.fileSize(source) ?? 0
            let hash = try store.hashCache.digest(source, forceFull: true).lowercased()
            let recorded = recipe.localExperimental?.associatedFiles.first { $0.path == path }?.sha256
            if [expectedAdditionalHashes[path], recorded].compactMap({ $0 }).contains(where: { $0.lowercased() != hash }) {
                throw LocalAPKVariantError.invalidRecord("O arquivo mudou desde a revisão: \(source.path)")
            }
            guard !recipeFiles.contains(where: { StagePlan.destination(for: $0) == "Documents/\(destination)" }) else {
                throw LocalAPKVariantError.invalidRecord("Destino adicional conflita com arquivo da receita: \(destination)")
            }
            guard selectedDestinations.insert(destination).inserted else {
                throw LocalAPKVariantError.invalidRecord("Dois arquivos adicionais usam o mesmo destino: \(destination)")
            }
            assets.append(LocalAPKAsset(name: "extra-\(hash.prefix(16))-\(name)", sourcePath: source.standardizedFileURL.path,
                sourceRootPath: source.deletingLastPathComponent().standardizedFileURL.path, size: size, sha256: hash,
                recipeSizeMatches: true, recipeHashMatches: nil, destination: destination,
                classification: Self.classification(source), origin: source.standardizedFileURL.path, isAdditional: true,
                automaticallyIncluded: automaticAdditionalPaths.contains(path)))
        }
        try Task.checkCancellation()
        return try store.register(from: apk, recipe: recipe, assets: assets,
                                  sourceRootPath: discovery.root.path,
                                  originalAPKSourcePath: apk.resolvingSymlinksInPath().path,
                                  missingRequiredFiles: discovery.missingRequired, progress: progress)
    }

    public static func safeAdditionalDestination(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.split(separator: "/").contains(".."),
              !path.split(separator: "/").contains("."), path.utf8.count <= 1024 else { return false }
        return path.split(separator: "/").allSatisfy { !$0.isEmpty && $0 != ".DS_Store" }
    }
}

private extension Array where Element == URL {
    func uniqued(by key: (URL) -> String) -> [URL] {
        var seen = Set<String>()
        return filter { seen.insert(key($0)).inserted }
    }
}
