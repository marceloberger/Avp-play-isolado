import Foundation

/// A locally supplied APK with its own integrity record. Its hash is a local change detector,
/// not evidence that Meta, the recipe author, or the original publisher approved the file.
public struct LocalAPKVariant: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var recipeID: String
    public var recipeVersionCode: Int
    /// Relative to `LocalAPKVariantStore.root`, never to the temporary import location.
    public var relativePath: String
    public var size: Int64
    public var sha256: String
    public var package: String
    public var versionCode: String
    public var versionName: String?
    public var architectures: [String]
    /// An observed label only; it is not treated as a trusted publisher identity.
    public var certificateSubjectObserved: String?
    public var androidSignature: AndroidAPKSignature?
    public var source: String
    public var trustStatus: String
    public var official: Bool
    public var recipeValidated: Bool
    public var assets: [LocalAPKAsset]?
    public var sourceRootPath: String?
    public var originalAPKSourcePath: String?
    public var packageMatchesRecipe: Bool?
    public var versionMatchesRecipe: Bool?
    public var officialAPKHashMatchesRecipe: Bool?
    public var missingRequiredFiles: [String]?
    public var registeredAt: Date
}

public struct LocalAPKAsset: Codable, Sendable, Equatable {
    public var name: String
    /// Absolute, read-only source reference. Large OBB/data files remain on the external drive.
    public var sourcePath: String
    /// Canonical authorization boundary for this file. Older records use the variant-wide source root.
    public var sourceRootPath: String?
    public var size: Int64
    public var sha256: String
    public var recipeSizeMatches: Bool
    public var recipeHashMatches: Bool?
    /// Optional local extension: destination below Documents/, selected by safe inference or explicit review.
    public var destination: String? = nil
    public var classification: String? = nil
    public var origin: String? = nil
    public var isAdditional: Bool? = nil
    public var automaticallyIncluded: Bool? = nil

    public func additionalRecipeFile() throws -> RecipeFile {
        guard isAdditional == true, let destination, LocalGameImport.safeAdditionalDestination(destination) else {
            throw LocalAPKVariantError.invalidRecord("Asset adicional sem destino validado: \(name)")
        }
        let path = destination as NSString
        return RecipeFile(name: name, role: "asset", id: "local-\(sha256.prefix(24))",
            size: size, sha256: sha256, required: false,
            dest: path.deletingLastPathComponent, localName: path.lastPathComponent)
    }
}

public enum LocalAPKVariantError: Error, CustomStringConvertible, Equatable {
    case missing(String)
    case invalidRecord(String)
    case unsafePath(String)
    case sizeMismatch(expected: Int64, actual: Int64)
    case hashMismatch(expected: String, actual: String)
    case packageMismatch(expected: String, actual: String)
    case versionMismatch(expected: String, actual: String)
    case architectureMismatch(expected: String, actual: [String])
    case recipeMismatch(String)
    case sourceMismatch(String)

    public var description: String {
        switch self {
        case .missing(let path): return "Local APK variant is missing: \(path)"
        case .invalidRecord(let detail): return "Local APK variant record is invalid: \(detail)"
        case .unsafePath(let path): return "Local APK variant has an unsafe path: \(path)"
        case .sizeMismatch(let expected, let actual): return "Local APK size changed (recorded \(expected), now \(actual))"
        case .hashMismatch(let expected, let actual): return "Local APK SHA-256 changed (recorded \(expected), now \(actual))"
        case .packageMismatch(let expected, let actual): return "Local APK package mismatch (expected \(expected), found \(actual))"
        case .versionMismatch(let expected, let actual): return "Local APK version mismatch (expected \(expected), found \(actual))"
        case .architectureMismatch(let expected, let actual): return "Local APK architecture mismatch (requires \(expected), found \(actual.joined(separator: ", ")))"
        case .recipeMismatch(let id): return "Local APK variant does not belong to recipe \(id)"
        case .sourceMismatch(let detail): return "Local APK variant is not marked as an unverified local file: \(detail)"
        }
    }
}

public struct ValidatedLocalAPKVariant: Sendable {
    public let variant: LocalAPKVariant
    public let apk: URL
    public let inspection: ApkUnpacker.Inspection
}

/// Persistent local APK registry, deliberately separate from `ContentStore` and Meta downloads.
public struct LocalAPKVariantStore: Sendable {
    public let root: URL
    private let cacheOverride: SHA256FileCache?
    public var hashCache: SHA256FileCache { cacheOverride ?? SHA256FileCache(root: root.appendingPathComponent(".sha256-cache")) }

    public init(root: URL = DataLocation.base.appendingPathComponent("local-variants", isDirectory: true)) {
        self.root = root; cacheOverride = nil
    }

    init(root: URL, hashCache: SHA256FileCache) {
        self.root = root; cacheOverride = hashCache
    }

    public func register(from source: URL, recipe: Recipe, certificateSubjectObserved: String? = nil,
                         expectedSize: Int64? = nil, expectedSHA256: String? = nil,
                         assets: [LocalAPKAsset] = [], sourceRootPath: String? = nil,
                         originalAPKSourcePath: String? = nil, missingRequiredFiles: [String]? = nil,
                         progress: @Sendable (LocalImportProgress) -> Void = { _ in }) throws -> LocalAPKVariant {
        guard Recipe.isSafeName(recipe.id), Recipe.isSafeName(String(recipe.versionCode)) else {
            throw LocalAPKVariantError.unsafePath(recipe.id)
        }
        guard let sourceSize = ContentStore.fileSize(source) else { throw LocalAPKVariantError.missing(source.path) }
        let sourceHash = try hashCache.digest(source, progress: { done, total, _ in
            progress(LocalImportProgress(phase: "Verificando APK", done: done, total: total))
        }).lowercased()
        if let expectedSize, sourceSize != expectedSize {
            throw LocalAPKVariantError.sizeMismatch(expected: expectedSize, actual: sourceSize)
        }
        if let expectedSHA256, sourceHash != expectedSHA256.lowercased() {
            throw LocalAPKVariantError.hashMismatch(expected: expectedSHA256.lowercased(), actual: sourceHash)
        }
        let inspection = try ApkUnpacker().inspect(apk: source)
        try Self.validatePackageAndArchitecture(inspection, recipe: recipe)

        try Task.checkCancellation()
        progress(LocalImportProgress(phase: "Verificando integridade"))
        let signature = try AndroidAPKSignature.inspect(source)
        guard signature.state != "invalid" else {
            throw LocalAPKVariantError.invalidRecord("APK rejeitado pela verificação Android: \(signature.detail)")
        }
        let id = "\(recipe.id)-\(recipe.versionCode)-\(sourceHash.prefix(12))"
        let relativePath = "\(recipe.id)-\(recipe.versionCode)/\(sourceHash).apk"
        guard Self.safeRelativePath(relativePath) else { throw LocalAPKVariantError.unsafePath(relativePath) }
        let destinationDirectory = root.appendingPathComponent("\(recipe.id)-\(recipe.versionCode)", isDirectory: true)
        let destination = root.appendingPathComponent(relativePath)
        try secureDirectory(root)
        try secureDirectory(destinationDirectory)

        if FileManager.default.fileExists(atPath: destination.path) {
            try verifyFile(destination, expectedSize: sourceSize, expectedSHA256: sourceHash, progress: progress)
        } else {
            let staging = destinationDirectory.appendingPathComponent(".incoming-\(UUID().uuidString).apk")
            defer { try? FileManager.default.removeItem(at: staging) }
            try Self.copyForImport(source, to: staging, total: sourceSize, progress: progress)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.path)
            try verifyFile(staging, expectedSize: sourceSize, expectedSHA256: sourceHash, progress: progress)
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: staging, to: destination)
        }

        let variant = LocalAPKVariant(
            id: id, recipeID: recipe.id, recipeVersionCode: recipe.versionCode,
            relativePath: relativePath, size: sourceSize, sha256: sourceHash,
            package: inspection.package ?? "", versionCode: inspection.versionCode ?? "",
            versionName: inspection.versionName, architectures: inspection.architectures.sorted(),
            certificateSubjectObserved: signature.subject ?? certificateSubjectObserved, androidSignature: signature, source: "local",
            trustStatus: Self.status(inspection: inspection, sourceHash: sourceHash, recipe: recipe),
            official: false, recipeValidated: false, assets: assets,
            sourceRootPath: sourceRootPath, originalAPKSourcePath: originalAPKSourcePath,
            packageMatchesRecipe: inspection.package == recipe.package,
            versionMatchesRecipe: inspection.versionCode == String(recipe.versionCode),
            officialAPKHashMatchesRecipe: recipe.files.first(where: { $0.role == "apk" })?.sha256.map { $0.lowercased() == sourceHash } ?? false,
            missingRequiredFiles: missingRequiredFiles,
            registeredAt: variants(for: recipe).first(where: { $0.id == id })?.registeredAt ?? Date()
        )
        let metadata = metadataURL(id: id, recipe: recipe)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(variant)
        try Task.checkCancellation()
        if let previous = try? Data(contentsOf: metadata), previous != data {
            let history = metadata.deletingLastPathComponent().appendingPathComponent(".metadata-history", isDirectory: true)
            try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
            try previous.write(to: history.appendingPathComponent("\(UUID().uuidString).json"), options: .atomic)
        }
        try data.write(to: metadata, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadata.path)
        return variant
    }

    static func copyForImport(_ source: URL, to destination: URL, total: Int64,
                              progress: @Sendable (LocalImportProgress) -> Void) throws {
        try Task.checkCancellation()
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw LocalAPKVariantError.invalidRecord("Não foi possível copiar o APK.")
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var done: Int64 = 0
        while let block = try input.read(upToCount: 8 << 20), !block.isEmpty {
            try Task.checkCancellation()
            try output.write(contentsOf: block)
            done += Int64(block.count)
            progress(LocalImportProgress(phase: "Copiando APK", done: done, total: total))
        }
        try output.synchronize()
        try Task.checkCancellation()
    }

    public func variants(for recipe: Recipe) -> [LocalAPKVariant] {
        let directory = root.appendingPathComponent("\(recipe.id)-\(recipe.versionCode)", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(LocalAPKVariant.self, from: Data(contentsOf: $0)) }
            .filter { $0.recipeID == recipe.id && $0.recipeVersionCode == recipe.versionCode }
            .sorted { $0.registeredAt < $1.registeredAt }
    }

    public func refreshSignature(id: String, recipe: Recipe) throws -> LocalAPKVariant {
        let selected = try validated(id: id, for: recipe, verifyAssetHashes: false)
        var variant = selected.variant
        variant.androidSignature = try AndroidAPKSignature.inspect(selected.apk)
        variant.certificateSubjectObserved = variant.androidSignature?.subject
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(variant).write(to: metadataURL(id: id, recipe: recipe), options: .atomic)
        return variant
    }

    public static func requireCompatibleDependencies(_ variant: LocalAPKVariant, recipe: Recipe) throws {
        try validateMetadata(ApkUnpacker.Inspection(package: variant.package, versionCode: variant.versionCode,
            versionName: variant.versionName, architectures: Set(variant.architectures), files: 0), recipe: recipe)
        for file in recipe.files where file.required && file.role != "apk" {
            guard let asset = variant.assets?.first(where: { $0.name == file.name }) else {
                throw LocalAPKVariantError.missing(file.name)
            }
            if let size = file.size, size != asset.size {
                throw LocalAPKVariantError.sizeMismatch(expected: size, actual: asset.size)
            }
            if let hash = file.sha256, hash.lowercased() != asset.sha256.lowercased() {
                throw LocalAPKVariantError.hashMismatch(expected: hash, actual: asset.sha256)
            }
        }
    }

    private static let preparationValidationLock = NSLock()
    private struct PreparationValidation: Codable, Equatable {
        var schema = 1
        var recipe: String
        var metadata: String
        var files: [SHA256FileCache.Identity]
    }

    /// Checks whether an earlier full preparation validation is still reusable from trusted local
    /// filesystem identity and its persisted SHA cache. It performs metadata/stat reads only; unreliable
    /// filesystems or changed identities return false and require the normal full validation path.
    public func hasReusablePreparationValidation(id: String, for recipe: Recipe,
                                                  expected variant: LocalAPKVariant) -> Bool {
        guard Recipe.isSafeName(id), id == variant.id, Recipe.isSafeName(recipe.id),
              variant.recipeID == recipe.id, variant.recipeVersionCode == recipe.versionCode,
              variant.source == "local", !variant.official, !variant.recipeValidated else { return false }
        do {
            let metadataURL = metadataURL(id: id, recipe: recipe)
            let metadata = try Data(contentsOf: metadataURL)
            let stored = try JSONDecoder().decode(LocalAPKVariant.self, from: metadata)
            guard stored == variant else { return false }
            try Self.requireCompatibleDependencies(stored, recipe: recipe)
            guard Self.safeRelativePath(stored.relativePath) else { return false }
            let urls = [root.appendingPathComponent(stored.relativePath)]
                + (stored.assets ?? []).map { URL(fileURLWithPath: $0.sourcePath) }
            let current = PreparationValidation(
                recipe: try LocalAPKBuildEvidence.recipeHash(KleptonRecipeCompatibility.resolve(recipe)),
                metadata: Hashing.sha256(of: metadata),
                files: try urls.map { try hashCache.currentIdentity($0) })
            guard current.files.allSatisfy(\.reliable) else { return false }
            let receiptURL = root.appendingPathComponent(".preparation-validations", isDirectory: true)
                .appendingPathComponent(id + ".json")
            guard (try? receiptURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                  let receiptData = try? Data(contentsOf: receiptURL),
                  let receipt = try? JSONDecoder().decode(PreparationValidation.self, from: receiptData),
                  receipt == current else { return false }
            let expectedHashes = [stored.sha256] + (stored.assets ?? []).map(\.sha256)
            guard urls.count == expectedHashes.count else { return false }
            for (url, expectedHash) in zip(urls, expectedHashes) {
                guard let cached = hashCache.cachedDigestIfCurrent(url),
                      cached == expectedHash.lowercased() else { return false }
            }
            return true
        } catch {
            return false
        }
    }

    /// Import-time hash cache entries cannot satisfy the first preparation validation.
    /// A receipt is committed only after all inputs pass a full read and stay unchanged.
    public func validatedForPreparation(id: String, for recipe: Recipe, forceFull: Bool = false,
        progress: @Sendable (LocalValidationProgress) -> Void = { _ in }) throws -> ValidatedLocalAPKVariant {
        while !Self.preparationValidationLock.lock(before: Date().addingTimeInterval(0.1)) { try Task.checkCancellation() }
        defer { Self.preparationValidationLock.unlock() }
        guard Recipe.isSafeName(id), Recipe.isSafeName(recipe.id) else { throw LocalAPKVariantError.unsafePath(id) }
        func snapshot() throws -> PreparationValidation {
            let data = try Data(contentsOf: metadataURL(id: id, recipe: recipe))
            let variant = try JSONDecoder().decode(LocalAPKVariant.self, from: data)
            try Self.requireCompatibleDependencies(variant, recipe: recipe)
            guard Self.safeRelativePath(variant.relativePath) else { throw LocalAPKVariantError.unsafePath(variant.relativePath) }
            let urls = [root.appendingPathComponent(variant.relativePath)]
                + (variant.assets ?? []).map { URL(fileURLWithPath: $0.sourcePath) }
            return PreparationValidation(recipe: try LocalAPKBuildEvidence.recipeHash(KleptonRecipeCompatibility.resolve(recipe)),
                metadata: Hashing.sha256(of: data), files: try urls.map { try hashCache.currentIdentity($0) })
        }
        let before = try snapshot()
        let directory = root.appendingPathComponent(".preparation-validations", isDirectory: true)
        let receipt = directory.appendingPathComponent(id + ".json")
        let previous = (try? Data(contentsOf: receipt)).flatMap { try? JSONDecoder().decode(PreparationValidation.self, from: $0) }
        let reusable = !forceFull && before.files.allSatisfy { $0.reliable } && previous == before
        let message: String
        if forceFull { message = "Validação completa manual solicitada explicitamente; cache ignorado." }
        else if previous == nil { message = "Primeira validação de preparação: recibo completo ausente; leitura integral obrigatória." }
        else if !before.files.allSatisfy({ $0.reliable }) {
            let systems = Set(before.files.filter { !$0.reliable }.map(\.filesystem)).sorted().joined(separator: ", ")
            message = "Recibo anterior existe, mas \(systems) não fornece evidência suficiente da identidade atual dos arquivos. Nova leitura integral obrigatória; não é validação manual."
        } else if reusable {
            message = "Reutilizando validação anterior: receita, variante e identidade confiável de todos os arquivos inalteradas."
        } else { message = "Receita, variante ou identidade dos arquivos mudou; nova validação integral obrigatória." }
        hashCache.auditValidation(message)
        progress(LocalValidationProgress(file: "", index: 0, count: before.files.count, done: 0, total: 0, message: message))
        let selected = try validated(id: id, for: recipe, forceFull: !reusable, progress: progress)
        try Self.requireCompatibleDependencies(selected.variant, recipe: recipe)
        guard try snapshot() == before else {
            throw LocalAPKVariantError.invalidRecord("Os arquivos mudaram durante a validação. Tente novamente.")
        }
        try Task.checkCancellation()
        guard (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw LocalAPKVariantError.unsafePath(directory.path)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(before).write(to: receipt, options: .atomic)
        return selected
    }

    public func validated(id: String, for recipe: Recipe, verifyAssetHashes: Bool = true,
                          verifyAPKHash: Bool = true, cache: SHA256FileCache? = nil, forceFull: Bool = false,
                          selectedAssetNames: Set<String>? = nil,
                          progress: @Sendable (LocalValidationProgress) -> Void = { _ in }) throws -> ValidatedLocalAPKVariant {
        try Task.checkCancellation()
        guard Recipe.isSafeName(id) else { throw LocalAPKVariantError.unsafePath(id) }
        let metadata = metadataURL(id: id, recipe: recipe)
        guard let data = try? Data(contentsOf: metadata),
              let variant = try? JSONDecoder().decode(LocalAPKVariant.self, from: data) else {
            throw LocalAPKVariantError.missing(metadata.path)
        }
        guard variant.id == id, variant.recipeID == recipe.id, variant.recipeVersionCode == recipe.versionCode else {
            throw LocalAPKVariantError.recipeMismatch(recipe.id)
        }
        guard variant.source == "local", variant.official == false, variant.recipeValidated == false else {
            throw LocalAPKVariantError.sourceMismatch(variant.trustStatus)
        }
        guard Self.safeRelativePath(variant.relativePath) else { throw LocalAPKVariantError.unsafePath(variant.relativePath) }
        let apk = root.appendingPathComponent(variant.relativePath)
        let count = 1 + (variant.assets?.count ?? 0)
        func digest(_ url: URL, index: Int, size: Int64) throws -> String {
            do {
                let cache = cache ?? hashCache
                return try cache.digest(url, forceFull: forceFull, log: { message in
                    progress(LocalValidationProgress(file: url.lastPathComponent, index: index, count: count,
                                                     done: 0, total: size, message: message))
                }) { done, total, cached in
                    progress(LocalValidationProgress(file: url.lastPathComponent, index: index, count: count,
                                                     done: done, total: total, cached: cached))
                }.lowercased()
            }

        }
        guard let actualSize = ContentStore.fileSize(apk) else { throw LocalAPKVariantError.missing(apk.path) }
        guard actualSize == variant.size else { throw LocalAPKVariantError.sizeMismatch(expected: variant.size, actual: actualSize) }
        if verifyAPKHash {
            let actualHash = try digest(apk, index: 1, size: variant.size)
            guard actualHash == variant.sha256.lowercased() else {
                throw LocalAPKVariantError.hashMismatch(expected: variant.sha256.lowercased(), actual: actualHash)
            }
        }
        if verifyAPKHash {
            let signature = try AndroidAPKSignature.inspect(apk)
            guard signature.state != "invalid" else {
                throw LocalAPKVariantError.invalidRecord("APK rejeitado pela verificação Android: \(signature.detail)")
            }
        }
        let inspection = try ApkUnpacker().inspect(apk: apk)
        try Self.validatePackageAndArchitecture(inspection, recipe: recipe)
        guard inspection.package == variant.package else {
            throw LocalAPKVariantError.packageMismatch(expected: variant.package, actual: inspection.package ?? "")
        }
        guard inspection.versionCode == variant.versionCode else {
            throw LocalAPKVariantError.versionMismatch(expected: variant.versionCode, actual: inspection.versionCode ?? "")
        }
        guard inspection.versionName == variant.versionName else {
            throw LocalAPKVariantError.versionMismatch(expected: variant.versionName ?? "", actual: inspection.versionName ?? "")
        }
        guard inspection.architectures.sorted() == variant.architectures.sorted() else {
            throw LocalAPKVariantError.architectureMismatch(expected: variant.architectures.joined(separator: ", "), actual: inspection.architectures.sorted())
        }
        var assetNames = Set<String>()
        for (index, asset) in (variant.assets ?? []).enumerated() {
            try Task.checkCancellation()
            guard Recipe.isSafeName(asset.name), assetNames.insert(asset.name).inserted else {
                throw LocalAPKVariantError.unsafePath(asset.name)
            }
            // Only recipe-declared, unselected optional files may be omitted. Unknown files stay strict.
            let declared = (recipe.files + (recipe.addons?.items ?? []).map { $0.asFile(dest: recipe.addons?.dest) })
                .first { $0.name == asset.name }
            if let names = selectedAssetNames, let declared, !declared.required, !names.contains(asset.name) { continue }
            if selectedAssetNames != nil, let declared {
                if let expected = declared.size, expected != asset.size {
                    throw LocalAPKVariantError.sizeMismatch(expected: expected, actual: asset.size)
                }
                if let expected = declared.sha256, expected.lowercased() != asset.sha256.lowercased() {
                    throw LocalAPKVariantError.hashMismatch(expected: expected, actual: asset.sha256)
                }
            }
            let source = URL(fileURLWithPath: asset.sourcePath).resolvingSymlinksInPath().standardizedFileURL
            guard let sourceRoot = (asset.sourceRootPath ?? variant.sourceRootPath).map({
                URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path
            }), source.path.hasPrefix(sourceRoot.hasSuffix("/") ? sourceRoot : sourceRoot + "/") else {
                throw LocalAPKVariantError.unsafePath(asset.sourcePath)
            }
            guard let actualSize = ContentStore.fileSize(source) else { throw LocalAPKVariantError.missing(source.path) }
            guard actualSize == asset.size else { throw LocalAPKVariantError.sizeMismatch(expected: asset.size, actual: actualSize) }
            if verifyAssetHashes {
                let actualHash = try digest(source, index: index + 2, size: asset.size)
                guard actualHash == asset.sha256 else {
                    throw LocalAPKVariantError.hashMismatch(expected: asset.sha256, actual: actualHash)
                }
            }
        }
        try Task.checkCancellation()
        return ValidatedLocalAPKVariant(variant: variant, apk: apk, inspection: inspection)
    }

    static func validatePackageAndArchitecture(_ inspection: ApkUnpacker.Inspection, recipe: Recipe) throws {
        if !recipe.package.isEmpty, inspection.package != recipe.package {
            throw LocalAPKVariantError.packageMismatch(expected: recipe.package, actual: inspection.package ?? "")
        }
        guard inspection.architectures.contains("arm64-v8a") else {
            throw LocalAPKVariantError.architectureMismatch(expected: "arm64-v8a", actual: inspection.architectures.sorted())
        }
    }

    static func status(inspection: ApkUnpacker.Inspection, sourceHash: String, recipe: Recipe) -> String {
        "local-unverified"
    }

    static func validateMetadata(_ inspection: ApkUnpacker.Inspection, recipe: Recipe) throws {
        let expected = recipe.package
        if !expected.isEmpty, inspection.package != expected {
            throw LocalAPKVariantError.packageMismatch(expected: expected, actual: inspection.package ?? "")
        }
        let expectedVersion = String(recipe.versionCode)
        guard inspection.versionCode == expectedVersion else {
            throw LocalAPKVariantError.versionMismatch(expected: expectedVersion, actual: inspection.versionCode ?? "")
        }
        guard inspection.architectures.contains("arm64-v8a") else {
            throw LocalAPKVariantError.architectureMismatch(expected: "arm64-v8a", actual: inspection.architectures.sorted())
        }
    }

    private func metadataURL(id: String, recipe: Recipe) -> URL {
        root.appendingPathComponent("\(recipe.id)-\(recipe.versionCode)", isDirectory: true)
            .appendingPathComponent("\(id).json")
    }

    private static func safeRelativePath(_ path: String) -> Bool {
        !path.hasPrefix("/") && !path.contains("\\") && !path.split(separator: "/").contains("..")
    }

    private func secureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func verifyFile(_ url: URL, expectedSize: Int64, expectedSHA256: String, progress: @Sendable (LocalImportProgress) -> Void = { _ in }) throws {
        guard let actualSize = ContentStore.fileSize(url) else { throw LocalAPKVariantError.missing(url.path) }
        guard actualSize == expectedSize else { throw LocalAPKVariantError.sizeMismatch(expected: expectedSize, actual: actualSize) }
        let actualHash = try hashCache.digest(url, progress: { done, total, _ in
            progress(LocalImportProgress(phase: "Verificando cópia do APK", done: done, total: total))
        }).lowercased()
        guard actualHash == expectedSHA256 else {
            throw LocalAPKVariantError.hashMismatch(expected: expectedSHA256, actual: actualHash)
        }
    }
}
