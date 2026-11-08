import Foundation

/// Immutable runtime inputs. Mutable saves and generated caches never enter this manifest.
enum InstallationContent {
    struct Entry: Equatable {
        var source: URL
        var destination: String
        var size: Int64
        var sha256: String
    }
    struct Container {
        var stat: (String) throws -> RemoteFile?
        var fetch: (String, URL) throws -> Void
        var put: (URL, String) throws -> Void
        var list: ((String) throws -> [RemoteFile])? = nil
    }
    struct Receipt: Codable, Equatable {
        var digest: String
        var size: Int64
        var modified: Date
    }

    static func loadReceipts(_ url: URL) throws -> [String: Receipt] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        // An unreadable receipt must never be silently replaced by an empty one.
        return try JSONDecoder().decode([String: Receipt].self, from: Data(contentsOf: url))
    }

    /// Read-only identity check before planning and again before each upload.
    /// A changed/unconfirmed container cannot inherit or erase the previous installation's receipts.
    static func installationScope(device: Device, bundle: String, apps: [InstalledApp],
                                  scopeFile: URL, receipts: URL) throws -> String {
        let matching = apps.filter { $0.bundleIdentifier == bundle }
        guard device.paired, device.reachable, device.developerMode,
              matching.count == 1, let identity = matching.first?.url,
              let url = URL(string: identity), url.isFileURL, !url.path.isEmpty else {
            throw DeviceError.tool("Identidade da instalação não confirmada: dispositivo=\(device.udid), Bundle ID=\(bundle). Nenhuma cópia autorizada; recibos preservados.")
        }
        let scope = device.udid + "|" + bundle + "|" + identity
        let previous = FileManager.default.fileExists(atPath: scopeFile.path)
            ? try String(contentsOf: scopeFile, encoding: .utf8) : nil
        let known = try loadReceipts(receipts)
        guard known.isEmpty || previous == scope else {
            throw DeviceError.tool("Identidade da instalação mudou ou não pôde ser vinculada aos recibos: dispositivo=\(device.udid), Bundle ID=\(bundle). Retomada interrompida; recibos preservados.")
        }
        return scope
    }

    /// Read every required path before any upload, including metadata after the OBBs.
    /// nil means proven absence; a failed/inconclusive stat throws and produces no transfer plan.
    static func preflight(_ entries: [Entry], stat: (String) throws -> RemoteFile?,
                          report: (String) -> Void = { _ in },
                          list: ((String) throws -> [RemoteFile])? = nil) throws -> [String: RemoteFile] {
        var result: [String: RemoteFile] = [:]
        // This snapshot belongs only to this read-only preflight. It is discarded
        // before any upload; live stats/readback still gate final verification.
        var directories: [String: [String: RemoteFile]] = [:]
        for entry in try unique(entries) {
            try Task.checkCancellation()
            report("Consultando arquivo remoto (stat): \(entry.destination)")
            do {
                let file: RemoteFile?
                if let list {
                    let parent = (entry.destination as NSString).deletingLastPathComponent
                    if directories[parent] == nil {
                        var children: [String: RemoteFile] = [:]
                        for child in try list(parent) {
                            guard !child.relativePath.isEmpty, child.relativePath != ".", child.relativePath != "..",
                                  !child.relativePath.contains("/"), !child.relativePath.contains("\\"),
                                  !child.relativePath.contains("\0"), children[child.relativePath] == nil else {
                                throw DeviceError.tool("Listagem remota inconclusiva: caminho ou nome duplicado em \(parent)")
                            }
                            children[child.relativePath] = child
                        }
                        directories[parent] = children
                    }
                    file = directories[parent]?[(entry.destination as NSString).lastPathComponent]
                } else { file = try stat(entry.destination) }
                if let file {
                    guard !file.isDirectory else {
                        throw DeviceError.tool("Destino obrigatório é diretório, não arquivo: \(entry.destination)")
                    }
                    result[entry.destination] = file
                } else {
                    report("Ausência remota confirmada (stat): \(entry.destination)")
                }
            } catch {
                // Preserve the exact file as well as the parent listing operation's context.
                throw DeviceError.tool("Falha em stat remoto: \(entry.destination). Nenhuma nova transferência autorizada. Causa: \(error)")
            }
        }
        return result
    }

    static func entry(source: URL, destination: String, expectedHash: String? = nil,
                      cache: SHA256FileCache = .shared) throws -> Entry {
        guard destination.hasPrefix("Documents/"), !destination.split(separator: "/").contains(".."),
              let size = ContentStore.fileSize(source) else {
            throw DeviceError.tool("Arquivo obrigatório ausente ou destino inválido: \(destination)")
        }
        let hash = try cache.digest(source).lowercased()
        if let expectedHash, hash != expectedHash.lowercased() {
            throw DeviceError.tool("SHA-256 da fonte diverge: \(destination)")
        }
        return Entry(source: source, destination: destination, size: size, sha256: hash)
    }

    /// Builds the final verification manifest from the same paths as the transfer plan.
    /// Frozen recipes without APK dest are supported by StagePlan, but no APK may disappear
    /// between recipe selection, initial copy planning and the final SHA-256 verification.
    static func recipeEntries(recipe: Recipe, local: [(file: RecipeFile, url: URL, size: Int64)],
                              cache: SHA256FileCache = .shared) throws -> [Entry] {
        for apk in recipe.files where apk.role == "apk" {
            guard apk.required, let expected = StagePlan.destination(for: apk),
                  let item = local.first(where: { $0.file.name == apk.name && $0.file.role == "apk" }),
                  item.size > 0, StagePlan.destination(for: item.file) == expected else {
                throw RecipeError.invalid("APK obrigatório ausente do manifesto Stage ou destino divergente: \(apk.name)")
            }
        }
        return try local.compactMap { item in
            guard let destination = StagePlan.destination(for: item.file) else { return nil }
            return try entry(source: item.url, destination: destination, expectedHash: item.file.sha256, cache: cache)
        }
    }

    /// Stage always includes the registered APK itself, independently of Build Only's
    /// extracted metadata. Never require a second APK in the shared toolchain/store.
    static func stageEntries(recipe: Recipe, local: [(file: RecipeFile, url: URL, size: Int64)],
                             toolchain: Toolchain, metadataWorkspace: URL,
                             associated: [Entry] = []) throws -> [Entry] {
        try unique(recipeEntries(recipe: recipe, local: local) + associated
            + prepared(toolchain: toolchain, recipe: recipe, metadataWorkspace: metadataWorkspace))
    }

    static func unique(_ entries: [Entry]) throws -> [Entry] {
        var result: [String: Entry] = [:]
        for entry in entries {
            if let other = result[entry.destination], other.sha256 != entry.sha256 || other.size != entry.size {
                throw DeviceError.tool("Fontes conflitantes para \(entry.destination)")
            }
            result[entry.destination] = entry
        }
        return result.values.sorted { $0.destination < $1.destination }
    }

    /// Mirrors the runtime contract: decoded metadata is beside assets, never inside it.
    static func prepared(toolchain: Toolchain, recipe: Recipe, metadataWorkspace: URL? = nil) throws -> [Entry] {
        guard recipe.files.contains(where: { $0.role == "apk" }) else { return [] }
        let resolved = KleptonRecipeCompatibility.resolve(recipe)
        let target = resolved.toolchain.target
        guard Recipe.isSafeName(target) else { throw RecipeError.invalid("invalid runtime tree") }
        // A completed Build Only owns the prepared Android metadata and assets in its isolated
        // workspace. Do not read them from the protected shared toolchain: Prepare may have
        // intentionally kept generated target files out of that tree.
        let sourceRoot = (metadataWorkspace ?? toolchain.root).standardizedFileURL
        let canonicalRoot = sourceRoot.resolvingSymlinksInPath().standardizedFileURL
        let tree = sourceRoot.appendingPathComponent(target, isDirectory: true)
        let canonicalTree = tree.resolvingSymlinksInPath().standardizedFileURL
        guard canonicalTree.path.hasPrefix(canonicalRoot.path + "/"),
              (try? tree.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw RecipeError.invalid("prepared metadata is outside the isolated workspace")
        }
        var result = try ["AndroidManifest.xml", "apktool.yml"].map {
            try entry(source: tree.appendingPathComponent($0), destination: "Documents/\(target)/\($0)")
        }
        let manifest = try String(contentsOf: tree.appendingPathComponent("AndroidManifest.xml"), encoding: .utf8)
        let yml = try String(contentsOf: tree.appendingPathComponent("apktool.yml"), encoding: .utf8)
        let package = resolved.package.isEmpty ? Self.manifestPackage(manifest) : resolved.package
        guard let package, !package.isEmpty,
              manifest.contains("package=\"\(package)\""),
              yml.split(separator: "\n").contains(where: {
                  $0.trimmingCharacters(in: .whitespaces) == "versionCode: \(recipe.versionCode)"
                  || $0.trimmingCharacters(in: .whitespaces) == "versionCode: '\(recipe.versionCode)'"
              }) else { throw RecipeError.invalid("Metadados preparados incompatíveis com o APK selecionado") }
        let assets = tree.appendingPathComponent("assets", isDirectory: true)
        let canonicalAssets = assets.resolvingSymlinksInPath().standardizedFileURL.path
        if let walker = FileManager.default.enumerator(at: assets, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let file as URL in walker where (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
                let canonicalFile = file.resolvingSymlinksInPath().standardizedFileURL.path
                guard canonicalFile.hasPrefix(canonicalAssets + "/") else {
                    throw RecipeError.invalid("asset outside prepared tree")
                }
                let relative = String(canonicalFile.dropFirst(canonicalAssets.count + 1))
                result.append(try entry(source: file, destination: "Documents/\(target)/assets/\(relative)"))
            }
        }
        // Native libraries are signed in the app. Qt plugins have their own explicit stage step.
        return try unique(result)
    }

    private static func manifestPackage(_ text: String) -> String? {
        guard let tag = text.range(of: "<manifest"),
              let end = text.range(of: ">", range: tag.upperBound..<text.endIndex),
              let key = text.range(of: " package=\"", range: tag.upperBound..<end.lowerBound),
              let close = text.range(of: "\"", range: key.upperBound..<end.lowerBound) else { return nil }
        let name = String(text[key.upperBound..<close.lowerBound])
        guard !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_") }),
              !name.contains("..") else { return nil }
        return name
    }

    /// Enumerate each parent independently: CoreDevice can truncate a recursive listing.
    /// A settled mutable data tree keeps user edits, but required paths must still exist.
    static func verifyTree(_ expected: [String: Int64], directory: String, allowModified: Bool,
                           list: (String) throws -> [RemoteFile]) throws {
        let groups = Dictionary(grouping: expected.keys) { ($0 as NSString).deletingLastPathComponent }
        for (parent, paths) in groups {
            try Task.checkCancellation()
            let folder = parent.isEmpty ? directory : "\(directory)/\(parent)"
            let files = try list(folder).filter { !$0.isDirectory }
            for path in paths {
                let name = (path as NSString).lastPathComponent
                guard let file = files.first(where: { $0.relativePath == name }),
                      allowModified || file.size == expected[path] else {
                    throw DeviceError.tool("Arquivo obrigatório ausente ou tamanho divergente: \(directory)/\(path). Use Resume.")
                }
            }
        }
    }

    /// First verification reads bytes back. Resume trusts only a receipt for the same container,
    /// digest, size and remote modification date. Missing/unreliable dates force a fresh read.
    struct SyncProgress182: Equatable {
        var filesVerified = 0
        var filesTotal = 0
        var bytesVerified: Int64 = 0
        var bytesTotal: Int64 = 0
        var bytesUploaded: Int64 = 0
        var bytesReadBack: Int64 = 0
        var receiptHits = 0
        var destination = ""
    }

    static func sync(_ entries: [Entry], container: Container, receipts: URL,
                     report: (String) -> Void = { _ in },
                     progress: (SyncProgress182) -> Void = { _ in }) throws {
        var known = try loadReceipts(receipts)
        let ordered = try unique(entries)
        _ = try preflight(ordered, stat: container.stat, report: report, list: container.list)
        let scratch = DataLocation.temporaryDirectory.appendingPathComponent("stage-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        var measured = SyncProgress182(filesTotal: ordered.count, bytesTotal: ordered.reduce(0) { $0 + $1.size })
        progress(measured)
        for entry in ordered {
            try Task.checkCancellation()
            measured.destination = entry.destination
            progress(measured)
            let previous = known
            func matches(_ remote: RemoteFile?) throws -> Bool {
                guard let remote, !remote.isDirectory, remote.size == entry.size else { return false }
                if let modified = remote.modified, let receipt = known[entry.destination],
                   receipt.modified == modified, receipt.size == remote.size, receipt.digest == entry.sha256 {
                    measured.receiptHits += 1
                    return true
                }
                let readback = scratch.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: readback) }
                try RemoteReadRetry182.run(report: report) {
                    try? FileManager.default.removeItem(at: readback)
                    try container.fetch(entry.destination, readback)
                }
                measured.bytesReadBack += ContentStore.fileSize(readback) ?? 0
                guard let after = try container.stat(entry.destination), after.size == remote.size,
                      after.modified == remote.modified else {
                    throw DeviceError.tool("Arquivo alterado durante a verificação: \(entry.destination). Use Resume.")
                }
                guard ContentStore.fileSize(readback) == entry.size else { return false }
                return try Hashing.sha256(of: readback) == entry.sha256
            }
            report("Consultando arquivo remoto (stat/verificação): \(entry.destination)")
            var remote: RemoteFile?
            do { remote = try container.stat(entry.destination) }
            catch { throw DeviceError.tool("Falha em stat/verificação remoto: \(entry.destination). Causa: \(error)") }
            if try !matches(remote) {
                report("Ausente ou divergente: \(entry.destination); completando transferência.")
                known.removeValue(forKey: entry.destination)
                try container.put(entry.source, entry.destination)
                measured.bytesUploaded += entry.size
                remote = try container.stat(entry.destination)
                guard try matches(remote) else { throw DeviceError.tool("Verificação de tamanho/SHA-256 falhou: \(entry.destination). Use Resume para completar a instalação.") }
            }
            if let modified = remote?.modified {
                known[entry.destination] = Receipt(digest: entry.sha256, size: entry.size, modified: modified)
            }
            if known != previous {
                try FileManager.default.createDirectory(at: receipts.deletingLastPathComponent(), withIntermediateDirectories: true)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                try encoder.encode(known).write(to: receipts, options: .atomic)
            }
            measured.filesVerified += 1
            measured.bytesVerified += entry.size
            progress(measured)
            report("Verificado: \(entry.destination) (\(entry.size) bytes, SHA-256).")
        }
    }
}
