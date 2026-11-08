import Foundation
import Darwin

public struct ReusableBuild: Sendable, Codable, Equatable {
    public let app: URL
    public let workspace: URL
    public let sourceJobID: String
    public let bundleID: String
    public let files: [String: String]

    static func sameOptions(_ a: InstallRequest, _ b: InstallRequest) -> Bool {
        (a.controllerMode ?? .standard) == (b.controllerMode ?? .standard)
            && a.experimental == b.experimental && a.metalFX == b.metalFX && a.resolution == b.resolution
            // `nil` is a legacy Job's explicit Off; Automatic is a distinct build identity.
            && (a.coreMods ?? false) == (b.coreMods ?? false) && (a.frameGeneration ?? .off) == (b.frameGeneration ?? .off)
            && (a.surrealSupport ?? true) == (b.surrealSupport ?? true) && (a.surrealSDK ?? .verified) == (b.surrealSDK ?? .verified)
            && a.localAssetsSHA256 == b.localAssetsSHA256
            && a.xrPrediction == b.xrPrediction && a.roomMeasuring == b.roomMeasuring && a.gameLanguage == b.gameLanguage
            && a.displayName == b.displayName && a.displaySuffix == b.displaySuffix && a.customIcon == b.customIcon
    }

    /// Some Klepton APK targets intentionally leave KLTree empty. Require the APK name and
    /// explicit generator target in the frozen successful build log, never just an empty field.
    static func matchesTarget(info: [String: Any], recipe: Recipe, buildLog: String) -> Bool {
        let resolved = KleptonRecipeCompatibility.resolve(recipe), target = resolved.toolchain.target
        if info["KLTree"] as? String == target { return true }
        guard info["KLTree"] as? String == "",
              let apk = resolved.files.first(where: { $0.role == "apk" })?.localName,
              info["KLApkName"] as? String == apk else { return false }
        return buildLog.split(separator: "\n").contains { line in
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            return parts.count == 2 && parts[0] == "KLEPTON_TARGET" && parts[1] == target
        }
    }

    /// Build-only logs belong to one Job and record its exact output path. Older Jobs
    /// use the human-readable line; new Jobs also write the locale-independent marker.
    static func buildOnlyAppPath(in log: String) -> URL? {
        var paths = Set<String>()
        for line in log.split(whereSeparator: \.isNewline).map(String.init) {
            let marker = "AVPPLAY_BUILD_ONLY_APP_PATH="
            if let range = line.range(of: marker) {
                let value = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { paths.insert(value) }
                continue
            }
            let prefixes = ["Generic visionOS app built at ", "Generische visionOS-App gebaut unter "]
            guard let prefix = prefixes.first(where: { line.contains($0) }),
                  let start = line.range(of: prefix)?.upperBound,
                  let end = line[start...].range(of: ".app")?.upperBound else { continue }
            paths.insert(String(line[start..<end]))
        }
        guard paths.count == 1, let path = paths.first, path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    static func canonicalPath(_ url: URL) -> String {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// Validate the exact Build-only directory layout and bind its UUID to the Job's target.
    static func buildOnlyWorkspace(for app: URL, root: URL, target: String) -> URL? {
        let canonicalRoot = Self.canonicalPath(root)
        let canonicalApp = Self.canonicalPath(app)
        guard canonicalApp.hasPrefix(canonicalRoot + "/") else { return nil }
        let relative = String(canonicalApp.dropFirst(canonicalRoot.count + 1))
        let parts = relative.split(separator: "/").map(String.init)
        guard parts.count == 10, parts[0].hasPrefix(target + "-"),
              parts[1] == "visionos", parts[2] == "build", parts[3] == "avpplay-build-only",
              parts[5] == "DerivedData", parts[6] == "Build", parts[7] == "Products",
              parts[8] == "Debug-xros", parts[9].hasSuffix(".app") else { return nil }
        let workspaceID = String(parts[0].dropFirst(target.count + 1))
        guard UUID(uuidString: workspaceID) != nil, parts[4] == workspaceID else { return nil }
        let workspace = URL(fileURLWithPath: canonicalRoot, isDirectory: true).appendingPathComponent(parts[0], isDirectory: true)
        guard Self.canonicalPath(workspace).hasPrefix(canonicalRoot + "/") else { return nil }
        return workspace
    }

    /// Validate frozen Build-only outputs without editing the original Job, workspace or app.
    /// Native ctime is required by default. An archived build may bypass only that timestamp check
    /// when LocalBuildRecovery supplies a validated historical manifest and every current byte hashes to it.
    public static func find(jobs: JobStore, workspaceRoot: URL, recipe: Recipe, request: InstallRequest,
                            bundleID: String, apkHash: String, toolchain: Toolchain,
                            report: @Sendable (String) -> Void = { _ in },
                            snapshots: [Job]? = nil, snapshotLogs: [String: String] = [:],
                            verifiedLegacyManifest: VerifiedLegacyBuildManifest? = nil) throws -> ReusableBuild? {
        try RuntimePolicy177.requireSource(toolchain)
        let root = workspaceRoot.resolvingSymlinksInPath().standardizedFileURL
        for job in snapshots ?? jobs.all() where job.state == .finished && job.steps == [.buildOnly]
            && job.recipe.id == recipe.id && job.recipe.package == recipe.package && job.recipe.versionCode == recipe.versionCode
            && job.request.localAPKVariantID == request.localAPKVariantID && job.toolchainCommit == toolchain.commit()
            && sameOptions(job.request, request) {
            guard try LocalAPKBuildEvidence.recipeHash(job.recipe) == LocalAPKBuildEvidence.recipeHash(recipe) else { continue }
            report("[Reuso] Verificando o build do Job \(job.id).")
            let log = try snapshotLogs[job.id] ?? String(contentsOf: jobs.directory.appendingPathComponent("\(job.id).log"), encoding: .utf8)
            let target = KleptonRecipeCompatibility.resolve(recipe).toolchain.target
            let jobRoot = job.request.localWorkspaceRoot.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL } ?? root
            guard Self.canonicalPath(jobRoot) == Self.canonicalPath(root),
                  let app = Self.buildOnlyAppPath(in: log), log.contains(app.path),
                  let folder = Self.buildOnlyWorkspace(for: app, root: root, target: target) else {
                report("[Reuso] Job \(job.id): caminho do app ausente, ambíguo ou fora do workspace exato do target \(target); nenhum workspace irmão foi pesquisado.")
                continue
            }
            guard FileManager.default.fileExists(atPath: app.path) else {
                report("[Reuso] Job \(job.id): o app registrado no log não existe: \(app.path).")
                continue
            }
            report("[Reuso] Job \(job.id): workspace associado \(folder.lastPathComponent).")
                    let buildLog = try String(contentsOf: folder.appendingPathComponent("build-only.log"), encoding: .utf8)
                    guard buildLog.contains("** BUILD SUCCEEDED **"), buildLog.contains("[exit 0]") else { report("[Reuso] Sem confirmação de compilação concluída."); continue }
                    let stamp = try String(contentsOf: folder.appendingPathComponent("\(target)/.qi-prepared"), encoding: .utf8)
                    guard stamp.contains(":\(apkHash) "), stamp.contains(request.localAPKVariantID ?? "no-local-variant") else { report("[Reuso] O stamp não corresponde ao APK selecionado."); continue }
                    guard toolchain.version() == 850, toolchain.commit() == "cc2856c", job.toolchainCommit == "cc2856c" else { continue }
                    let tls168 = toolchain.version() == 850 && toolchain.commit() == "cc2856c"
                    if tls168 {
                        guard OptionalRuntime850.hasVerifiedReceipt(for: toolchain), try hasTLS168Overlay(in: folder) else {
                            report("[Reuso] Build 850 sem overlay TLS168 validado; artefato preservado."); continue
                        }
                    }
                    try RuntimePolicy177.requireWorkspace(Toolchain(root: folder), generatedTarget: target)
                    let info = try infoPlist(app.appendingPathComponent("Info.plist"))
                    guard info["CFBundleIdentifier"] as? String == bundleID,
                          info["CFBundleVersion"] as? String == AppStamp.build(versionCode: recipe.versionCode,
                            toolchainVersion: toolchain.version(), modified: tls168,
                            experimental: request.experimental == true && toolchain.supportsExperimental,
                            metalFX: request.metalFX == true && toolchain.supportsMetalFX,
                            resolution: toolchain.supportsRenderScalePreset ? request.resolution : nil,
                            xrPrediction: request.xrPrediction == true && toolchain.supportsXRPrediction,
                            coreMods: request.coreMods == true),
                          (info["CFBundleSupportedPlatforms"] as? [String])?.contains("XROS") == true,
                          matchesTarget(info: info, recipe: recipe, buildLog: buildLog),
                          info["KLControllerModeDefault"] as? String == (request.controllerMode ?? .standard).rawValue else { report("[Reuso] Bundle, versão, plataforma, alvo ou controles divergentes."); continue }
                    if toolchain.supportsRuntime824 {
                        guard matchesFrameGeneration(info: info, request: request, target: target, toolchain: toolchain),
                              (info["KLSurrealAvailable"] as? String != "NO") == (request.surrealSupport != false) else {
                            report("[Reuso] Configuração do runtime divergente; artefato preservado."); continue
                        }
                    }
                    guard let executable = info["CFBundleExecutable"] as? String, Recipe.isSafeName(executable),
                          FileManager.default.isExecutableFile(atPath: app.appendingPathComponent(executable).path) else {
                        throw LocalAPKVariantError.invalidRecord("O executável do build está ausente ou sem permissão de execução.")
                    }
                    let handle = try FileHandle(forReadingFrom: app.appendingPathComponent(executable))
                    let header = try handle.read(upToCount: 16) ?? Data(); try handle.close()
                    guard header.count == 16, Array(header.prefix(8)) == [0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0, 0, 1],
                          Array(header.suffix(4)) == [2, 0, 0, 0] else {
                        throw LocalAPKVariantError.invalidRecord("O artefato não contém um executável ARM64 visionOS compatível.")
                    }
                    let expectedRoom = (request.roomMeasuring ?? InstallDefaults.roomMeasuring()) ? "1" : "0"
                    let expectedLanguage = request.gameLanguage ?? InstallDefaults.gameLanguage() ?? ""
                    guard info["KLRoomGuardDefault"] as? String == expectedRoom,
                          info["KLGameLanguageDefault"] as? String == expectedLanguage else { report("[Reuso] Idioma ou medição de área diferentes."); continue }
                    let files: [String: String]
                    do {
                        files = try inventory(app, unchangedSince: job.updated.addingTimeInterval(1))
                    } catch let error as LocalAPKVariantError {
                        let timestampOnly: Bool
                        if case .invalidRecord(let detail) = error {
                            timestampOnly = detail.hasPrefix("Build anterior modificado ou sem metadados confiáveis:")
                                || detail.hasPrefix("Link do app alterado após o build:")
                        } else { timestampOnly = false }
                        let appPath = app.resolvingSymlinksInPath().standardizedFileURL.path
                        guard timestampOnly, let verifiedLegacyManifest,
                              verifiedLegacyManifest.buildJobID == job.id,
                              verifiedLegacyManifest.appPath == appPath else { throw error }
                        let current = try inventory(app)
                        guard try LocalAPKBuildEvidence.digest(current) == verifiedLegacyManifest.manifestSHA256 else {
                            throw LocalAPKVariantError.invalidRecord("O manifesto nativo atual diverge do hash histórico confirmado; reuso recusado.")
                        }
                        report("[Reuso] ctime posterior aceito somente após hash integral idêntico ao manifesto histórico da instalação confirmada.")
                        files = current
                    }
                    return ReusableBuild(app: app, workspace: folder, sourceJobID: job.id, bundleID: bundleID, files: files)
        }
        return nil
    }

    /// Automatic builds inherit the target's verified Klepton default. Old persisted Jobs with
    /// no setting retain explicit Off semantics. Manual choices must match the compiled app.
    static func matchesFrameGeneration(info: [String: Any], request: InstallRequest,
                                       target: String, toolchain: Toolchain) -> Bool {
        guard let actual = info["KLFrameGenDefault"] as? String else { return false }
        switch request.frameGeneration {
        case .automatic:
            return toolchain.frameGenerationDefault(for: target)?.rawValue == actual
        case .some(let selected):
            return selected.rawValue == actual
        case nil:
            return actual == FrameGeneration.off.rawValue
        }
    }

    static func hasTLS168Overlay(in workspace: URL) throws -> Bool {
        guard let manifest = Bundle.module.url(forResource: "tls170-overlay", withExtension: "json"),
              let marker = try? Data(contentsOf: workspace.appendingPathComponent(".experimental-tls170.json")),
              marker == (try Data(contentsOf: manifest)) else { return false }
        let overlay = try JSONDecoder().decode(ExperimentalTLS170.Overlay.self, from: marker)
        guard overlay.revision == "850-cc2856c-tls168", overlay.files.count == 4 else { return false }
        let root = workspace.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        return overlay.files.allSatisfy { entry in
            let file = workspace.appendingPathComponent(entry.path)
            guard Recipe.isSafeRelativePath(entry.path),
                  file.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root) else { return false }
            return (try? Hashing.sha256(of: file)) == entry.correctedSHA256
        }
    }

    static func infoPlist(_ path: URL) throws -> [String: Any] {
        guard let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: path), format: nil) as? [String: Any] else {
            throw LocalAPKVariantError.invalidRecord("Invalid app/profile metadata: \(path.lastPathComponent)")
        }
        return value
    }

    static func inventory(_ app: URL, unchangedSince cutoff: Date? = nil) throws -> [String: String] {
        let root = app.resolvingSymlinksInPath().standardizedFileURL
        guard let walker = FileManager.default.enumerator(atPath: root.path) else {
            throw LocalAPKVariantError.missing(app.path)
        }
        var files: [String: String] = [:]
        for case let relative as String in walker {
            let file = root.appendingPathComponent(relative)
            try Task.checkCancellation()
            guard file.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else { throw LocalAPKVariantError.unsafePath(file.path) }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                var metadata = stat()
                guard lstat(file.path, &metadata) == 0 else { throw LocalAPKVariantError.unsafePath(file.path) }
                if let cutoff, Double(metadata.st_ctimespec.tv_sec) + Double(metadata.st_ctimespec.tv_nsec) / 1e9 > cutoff.timeIntervalSince1970 {
                    throw LocalAPKVariantError.invalidRecord("Link do app alterado após o build: \(file.lastPathComponent)")
                }
                files[relative] = "symlink:" + (try FileManager.default.destinationOfSymbolicLink(atPath: file.path))
                continue
            }
            guard values.isRegularFile == true else { continue }
            let before = try SHA256FileCache.identity(file)
            if let cutoff {
                guard before.reliable, Double(before.ctime) + Double(before.ctimeNS) / 1e9 <= cutoff.timeIntervalSince1970 else {
                    throw LocalAPKVariantError.invalidRecord("Build anterior modificado ou sem metadados confiáveis: \(file.lastPathComponent). Não será assinado automaticamente.")
                }
            }
            let hash = try Hashing.sha256(of: file)
            guard try SHA256FileCache.identity(file) == before else { throw LocalAPKVariantError.invalidRecord("O app compilado mudou durante a verificação.") }
            files[relative] = hash
        }
        guard !files.isEmpty, files["Info.plist"] != nil else { throw LocalAPKVariantError.invalidRecord("App compilado incompleto") }
        return files
    }

    public func verifyCopy(_ copy: URL) throws {
        guard try Self.inventory(copy) == files else { throw LocalAPKVariantError.invalidRecord("Cópia do build não corresponde ao artefato verificado.") }
    }
}
