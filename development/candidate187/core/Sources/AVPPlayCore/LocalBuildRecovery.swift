import Foundation

/// Collects the verifier's per-candidate diagnostics while forwarding them to the Job/UI log.
private final class BuildRecoveryDiagnosticBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ value: String) {
        lock.lock(); defer { lock.unlock() }
        values.append(value)
    }

    func snapshot() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return values
    }
}

/// A recovery failure can include several rejected candidates; callers should display it without truncation.
public struct LocalBuildRecoveryFailure: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Provenance for a legacy artifact whose bytes were later restored from an archive.
/// Every value comes from an existing confirmed-installation evidence record.
public struct LocalBuildLegacyProvenance: Codable, Sendable, Equatable {
    public let format: Int
    public let installationReceiptID: String
    public let originalReceiptSHA256: String
    public let buildJobID: String
    public let buildJobSHA256: String
    public let buildLogSHA256: String
    public let manifestSHA256: String
    public let appPath: String
    public let variantID: String
    public let apkSHA256: String
    public let recipeSHA256: String
    public let bundleID: String
    public let teamID: String
    public let toolchain: String

    init(installation: LocalAPKInstallation, buildJobSHA256: String, buildLogSHA256: String,
         manifestSHA256: String, recipeSHA256: String, variant: LocalAPKVariant, appPath: String) {
        format = 1
        installationReceiptID = installation.id
        originalReceiptSHA256 = installation.legacyRecovery?.originalReceiptSHA256 ?? ""
        buildJobID = installation.legacyRecovery?.buildJobID ?? ""
        self.buildJobSHA256 = buildJobSHA256
        self.buildLogSHA256 = buildLogSHA256
        self.manifestSHA256 = manifestSHA256
        self.appPath = appPath
        variantID = variant.id
        apkSHA256 = variant.sha256
        self.recipeSHA256 = recipeSHA256
        bundleID = installation.bundleID
        teamID = installation.team
        toolchain = installation.toolchain
    }
}

/// A provenance value validated by LocalBuildRecovery against the confirmed local receipt,
/// its original Job/log hashes, recipe, variant, and current workspace evidence.
public struct VerifiedLegacyBuildManifest: Sendable {
    public let buildJobID: String
    public let appPath: String
    public let manifestSHA256: String

    init(provenance: LocalBuildLegacyProvenance) {
        buildJobID = provenance.buildJobID
        appPath = provenance.appPath
        manifestSHA256 = provenance.manifestSHA256
    }

    init(buildJobID: String, appPath: String, manifestSHA256: String) {
        self.buildJobID = buildJobID
        self.appPath = appPath
        self.manifestSHA256 = manifestSHA256
    }
}

/// Redundant evidence independent of the disposable Jobs list; never an installation receipt.
public struct LocalBuildReceipt: Codable, Sendable {
    public let jobData: Data
    public let logData: Data
    public let jobSHA256: String
    public let logSHA256: String
    public let artifact: ReusableBuild
    public let legacyProvenance: LocalBuildLegacyProvenance?
    public let localAssetsSHA256: String?
    public let localAssets: [LocalAPKAsset]?
    public let toolchainVersion: Int?
    public let toolchainCommit: String?
    public let tls168Revision: String?
    public let tls168OverlaySHA256: String?

    public init(jobData: Data, logData: Data, artifact: ReusableBuild,
                legacyProvenance: LocalBuildLegacyProvenance? = nil,
                variant: LocalAPKVariant? = nil) throws {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decodedJob = try decoder.decode(Job.self, from: jobData)
        guard decodedJob.id == artifact.sourceJobID,
              decodedJob.steps == [.buildOnly], decodedJob.completed == [.buildOnly],
              decodedJob.state == .finished, decodedJob.toolchainCommit == "cc2856c" else {
            throw LocalAPKVariantError.invalidRecord("O artefato não está associado ao Job Build Only concluído e compatível.")
        }
        let target = KleptonRecipeCompatibility.resolve(decodedJob.recipe).toolchain.target
        guard let workspaceRootPath = decodedJob.request.localWorkspaceRoot,
              let recordedApp = String(data: logData, encoding: .utf8).flatMap(ReusableBuild.buildOnlyAppPath(in:)),
              ReusableBuild.canonicalPath(recordedApp) == ReusableBuild.canonicalPath(artifact.app) else {
            throw LocalAPKVariantError.invalidRecord("O log do Job não vincula este recibo ao app Build Only registrado.")
        }
        let workspaceRoot = URL(fileURLWithPath: workspaceRootPath).resolvingSymlinksInPath().standardizedFileURL
        guard let exactWorkspace = ReusableBuild.buildOnlyWorkspace(for: artifact.app, root: workspaceRoot, target: target),
              ReusableBuild.canonicalPath(exactWorkspace) == ReusableBuild.canonicalPath(artifact.workspace) else {
            throw LocalAPKVariantError.invalidRecord("O workspace do recibo não corresponde ao caminho de Build Only deste Job.")
        }
        try RuntimePolicy177.requireArtifact(artifact, target: target)
        self.jobData = jobData; self.logData = logData; self.artifact = artifact
        self.legacyProvenance = legacyProvenance
        localAssetsSHA256 = try variant.map(LocalAPKBuildEvidence.assetsHash)
        localAssets = variant?.assets
        toolchainCommit = decodedJob.toolchainCommit
        toolchainVersion = try? Toolchain(root: URL(fileURLWithPath: decodedJob.request.toolchain)).version()
        let marker = artifact.workspace.appendingPathComponent(".experimental-tls170.json")
        if let data = try? Data(contentsOf: marker),
           let overlay = try? JSONDecoder().decode(ExperimentalTLS170.Overlay.self, from: data) {
            tls168Revision = overlay.revision
            tls168OverlaySHA256 = Hashing.sha256(of: data)
        } else { tls168Revision = nil; tls168OverlaySHA256 = nil }
        jobSHA256 = Hashing.sha256(of: jobData); logSHA256 = Hashing.sha256(of: logData)
        _ = try job()
    }
    public func job() throws -> Job {
        guard Hashing.sha256(of: jobData) == jobSHA256, Hashing.sha256(of: logData) == logSHA256 else {
            throw LocalAPKVariantError.invalidRecord("Recibo de compilação alterado; recuperação recusada.")
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let job = try decoder.decode(Job.self, from: jobData)
        guard toolchainCommit == nil || toolchainCommit == job.toolchainCommit,
              localAssetsSHA256 == nil || localAssetsSHA256 == job.request.localAssetsSHA256 else {
            throw LocalAPKVariantError.invalidRecord("Metadados de toolchain ou assets do recibo divergem do Job.")
        }
        // Persisted Jobs use the same narrowly scoped exception as JobStore.load:
        // local-community is valid only for the exact synthetic local APK recipe.
        // RecipeStore and other distributable recipe paths still call validate().
        try job.recipe.validateForJob()
        guard Recipe.isSafeName(job.id), job.id == artifact.sourceJobID,
              job.state == .finished, job.steps == [.buildOnly], job.completed == [.buildOnly],
              job.failure == nil, job.current == nil, job.request.localAPKVariantID != nil else {
            throw LocalAPKVariantError.invalidRecord("Sem comprovação de Build only concluído.")
        }
        if let legacyProvenance {
            let appPath = artifact.app.resolvingSymlinksInPath().standardizedFileURL.path
            guard legacyProvenance.format == 1, legacyProvenance.buildJobID == job.id,
                  legacyProvenance.buildJobSHA256 == jobSHA256,
                  legacyProvenance.buildLogSHA256 == logSHA256,
                  legacyProvenance.appPath == appPath,
                  legacyProvenance.variantID == job.request.localAPKVariantID,
                  legacyProvenance.bundleID == artifact.bundleID,
                  legacyProvenance.bundleID == job.request.bundleId,
                  legacyProvenance.teamID == job.request.team,
                  legacyProvenance.recipeSHA256 == (try LocalAPKBuildEvidence.recipeHash(job.recipe)),
                  legacyProvenance.manifestSHA256 == (try LocalAPKBuildEvidence.digest(artifact.files)),
                  [legacyProvenance.originalReceiptSHA256, legacyProvenance.buildJobSHA256,
                   legacyProvenance.buildLogSHA256, legacyProvenance.manifestSHA256,
                   legacyProvenance.apkSHA256, legacyProvenance.recipeSHA256]
                    .allSatisfy({ $0.count == 64 && $0.allSatisfy(\.isHexDigit) }) else {
                throw LocalAPKVariantError.invalidRecord("Proveniência histórica incompleta ou divergente; recuperação recusada.")
            }
        }
        return job
    }
}

public struct LocalBuildRecovery: Sendable {
    public let workspaceRoot: URL
    public init(workspaceRoot: URL) { self.workspaceRoot = workspaceRoot }
    public var directory: URL { workspaceRoot.appendingPathComponent(".build-receipts", isDirectory: true) }
    public func save(_ receipt: LocalBuildReceipt) throws {
        let job = try receipt.job()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent(job.id + ".json")
        if FileManager.default.fileExists(atPath: path.path) {
            let existing = try JSONDecoder().decode(LocalBuildReceipt.self, from: Data(contentsOf: path))
            guard existing.jobData == receipt.jobData, existing.logData == receipt.logData,
                  existing.artifact == receipt.artifact,
                  existing.legacyProvenance == receipt.legacyProvenance,
                  existing.localAssetsSHA256 == receipt.localAssetsSHA256,
                  existing.localAssets == receipt.localAssets,
                  existing.toolchainVersion == receipt.toolchainVersion,
                  existing.toolchainCommit == receipt.toolchainCommit,
                  existing.tls168Revision == receipt.tls168Revision,
                  existing.tls168OverlaySHA256 == receipt.tls168OverlaySHA256 else {
                throw LocalAPKVariantError.invalidRecord("Recibo existente divergente; não será substituído.")
            }
            return
        }
        try JSONEncoder().encode(receipt).write(to: path, options: .withoutOverwriting)
    }

    /// Reads native bytes only. Never prepares, compiles, signs or contacts a device.
    public func artifact(jobs: JobStore, recipe: Recipe, variant: LocalAPKVariant, toolchain: Toolchain,
                         legacyInstallations: [LocalAPKInstallation] = [],
                         variantStore: LocalAPKVariantStore? = nil,
                         requestedRuntime: InstallRequest? = nil,
                         report: @escaping @Sendable (String) -> Void = { _ in }) throws -> (ReusableBuild, Job)? {
        try RuntimePolicy177.requireSource(toolchain)
        let currentAssetsHash = try LocalAPKBuildEvidence.assetsHash(variant)
        let rejectionBuffer = BuildRecoveryDiagnosticBuffer()
        func reject(_ detail: String) {
            rejectionBuffer.append(detail)
            report("[Reuso] \(detail)")
        }
        func verifierReport(jobID: String, buffer: BuildRecoveryDiagnosticBuffer) -> @Sendable (String) -> Void {
            { message in
                let detail = "Job \(jobID), workspaceRoot=\(workspaceRoot.path): \(message)"
                buffer.append(detail)
                rejectionBuffer.append(detail)
                report(detail)
            }
        }
        func recordNoMatch(jobID: String, diagnostics: [String]) {
            let context = "Job \(jobID), workspaceRoot=\(workspaceRoot.path)"
            if diagnostics.isEmpty {
                reject("\(context): ReusableBuild.find retornou nil sem diagnóstico; nenhuma validação foi aceita.")
            } else {
                reject("\(context): ReusableBuild.find não aceitou o artefato. Diagnósticos: \(diagnostics.joined(separator: " | "))")
            }
        }
        if let requestedHash = requestedRuntime?.localAssetsSHA256, requestedHash != currentAssetsHash {
            throw LocalAPKVariantError.invalidRecord("A seleção de assets mudou desde a solicitação de instalação.")
        }
        // Jobs are examined newest-first before older catalog receipts. A fresh successful Build Only
        // therefore gets its own receipt even when an older incompatible receipt already exists.
        for job in jobs.all().sorted(by: { $0.created > $1.created }) where job.state == .finished && job.steps == [.buildOnly]
            && job.recipe.id == recipe.id && job.request.localAPKVariantID == variant.id
            && job.toolchainCommit == toolchain.commit()
            && (requestedRuntime == nil || Self.runtimeCompatible(job.request, with: requestedRuntime!)) {
            do {
            guard job.request.localAssetsSHA256 == currentAssetsHash else {
                reject("Job \(job.id), arquivo \(jobs.url(job.id).path): localAssetsSHA256 não corresponde à variante atual; Job preservado e ignorado."); continue
            }
            let bundle = job.request.bundleId ?? Toolchain.defaultBundleId(target: KleptonRecipeCompatibility.resolve(recipe).toolchain.target)
            let jobData = try Data(contentsOf: jobs.url(job.id))
            let logData = try Data(contentsOf: jobs.directory.appendingPathComponent(job.id + ".log"))
            let log = String(decoding: logData, as: UTF8.self)
            let searchDiagnostics = BuildRecoveryDiagnosticBuffer()
            if let found = try ReusableBuild.find(jobs: jobs, workspaceRoot: workspaceRoot, recipe: recipe,
                request: job.request, bundleID: bundle, apkHash: variant.sha256, toolchain: toolchain,
                report: verifierReport(jobID: job.id, buffer: searchDiagnostics),
                snapshots: [job], snapshotLogs: [job.id: log]) {
                let receipt = try LocalBuildReceipt(jobData: jobData, logData: logData, artifact: found, variant: variant)
                do { try save(receipt) }
                catch {
                    reject("Job \(job.id), recibo \(directory.appendingPathComponent(job.id + ".json").path): não foi possível gravar a evidência validada sem substituir dados existentes: \(error)")
                    continue
                }
                return (found, job)
            } else {
                recordNoMatch(jobID: job.id, diagnostics: searchDiagnostics.snapshot())
            }
            } catch {
                reject("Job \(job.id), workspaceRoot=\(workspaceRoot.path), arquivo de Job=\(jobs.url(job.id).path): verificação do artefato/recibo falhou: \(error)")
                continue
            }
        }
        let receipts = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for path in receipts.sorted(by: { $0.path < $1.path }) where path.pathExtension == "json" && path.lastPathComponent.hasPrefix(recipe.id + "-") {
            do {
            let receipt: LocalBuildReceipt
            do {
                receipt = try JSONDecoder().decode(LocalBuildReceipt.self, from: Data(contentsOf: path))
            } catch {
                reject("Recibo \(path.path): decodificação falhou; recibo preservado e ignorado: \(error)")
                continue
            }
            let job: Job
            do {
                job = try receipt.job()
            } catch {
                reject("Recibo \(path.path): comprovação do Build falhou; recibo preservado e ignorado: \(error)")
                continue
            }
            var receiptMismatches: [String] = []
            if job.recipe.id != recipe.id { receiptMismatches.append("recipeID") }
            if job.request.localAPKVariantID != variant.id { receiptMismatches.append("variantID") }
            if job.toolchainCommit != toolchain.commit() { receiptMismatches.append("toolchainCommit") }
            if job.request.localAssetsSHA256 != currentAssetsHash { receiptMismatches.append("Job.localAssetsSHA256") }
            if receipt.localAssetsSHA256 != currentAssetsHash { receiptMismatches.append("receipt.localAssetsSHA256") }
            if requestedRuntime != nil && !Self.runtimeCompatible(job.request, with: requestedRuntime!) {
                receiptMismatches.append("runtime settings")
            }
            guard receiptMismatches.isEmpty else {
                reject("Recibo \(path.path): incompatível em \(receiptMismatches.joined(separator: ", ")); não foi reutilizado.")
                continue
            }
            guard let log = String(data: receipt.logData, encoding: .utf8) else {
                throw LocalAPKVariantError.invalidRecord("Log do recibo não é UTF-8; reuso bloqueado.")
            }
            let provenance = try validatedLegacyProvenance(job: job, jobData: receipt.jobData,
                logData: receipt.logData, appPath: receipt.artifact.app.path, recipe: recipe,
                variant: variant, toolchain: toolchain, jobs: jobs,
                installations: legacyInstallations, variantStore: variantStore)
            guard receipt.legacyProvenance == provenance else {
                throw LocalAPKVariantError.invalidRecord("A proveniência histórica do recibo não corresponde à instalação confirmada.")
            }
            let searchDiagnostics = BuildRecoveryDiagnosticBuffer()
            guard let found = try ReusableBuild.find(jobs: jobs, workspaceRoot: workspaceRoot,
                recipe: recipe, request: job.request, bundleID: receipt.artifact.bundleID,
                apkHash: variant.sha256, toolchain: toolchain,
                report: verifierReport(jobID: job.id, buffer: searchDiagnostics),
                snapshots: [job], snapshotLogs: [job.id: log],
                verifiedLegacyManifest: provenance.map(VerifiedLegacyBuildManifest.init)) else {
                let diagnostics = searchDiagnostics.snapshot()
                recordNoMatch(jobID: job.id, diagnostics: diagnostics.isEmpty
                    ? ["recibo=\(path.path): ReusableBuild.find não validou o artefato registrado"] : diagnostics)
                continue
            }
            let sameApp = found.app.resolvingSymlinksInPath().standardizedFileURL.path
                == receipt.artifact.app.resolvingSymlinksInPath().standardizedFileURL.path
            let sameWorkspace = found.workspace.resolvingSymlinksInPath().standardizedFileURL.path
                == receipt.artifact.workspace.resolvingSymlinksInPath().standardizedFileURL.path
            guard sameApp, sameWorkspace, found.sourceJobID == receipt.artifact.sourceJobID,
                  found.bundleID == receipt.artifact.bundleID, found.files == receipt.artifact.files else {
                report("[Reuso] Comparação canônica: app=\(sameApp), workspace=\(sameWorkspace), job=\(found.sourceJobID == receipt.artifact.sourceJobID), bundle=\(found.bundleID == receipt.artifact.bundleID), arquivos=\(found.files == receipt.artifact.files). appPaths=\(found.app.resolvingSymlinksInPath().standardizedFileURL.path)|\(receipt.artifact.app.resolvingSymlinksInPath().standardizedFileURL.path); workspacePaths=\(found.workspace.resolvingSymlinksInPath().standardizedFileURL.path)|\(receipt.artifact.workspace.resolvingSymlinksInPath().standardizedFileURL.path).")
                throw LocalAPKVariantError.invalidRecord("Compilação mudou ou não corresponde ao recibo; reuso bloqueado.")
            }
            try validateLegacyWorkspace(provenance, artifact: found, recipe: recipe,
                                        installations: legacyInstallations)
            for (name, data) in [(job.id + ".log", receipt.logData), (job.id + ".json", receipt.jobData)] {
                let dest = jobs.directory.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: dest.path) {
                    guard try Data(contentsOf: dest) == data else { throw LocalAPKVariantError.invalidRecord("Job ou log existente divergente; recuperação bloqueada.") }
                }
            }
            try FileManager.default.createDirectory(at: jobs.directory, withIntermediateDirectories: true)
            for (name, data) in [(job.id + ".log", receipt.logData), (job.id + ".json", receipt.jobData)] {
                let dest = jobs.directory.appendingPathComponent(name)
                if !FileManager.default.fileExists(atPath: dest.path) { try data.write(to: dest, options: .withoutOverwriting) }
            }
            report("Registro original recuperado; \(found.files.count) arquivos nativos validados, sem leitura dos dados externos.")
            return (receipt.artifact, job)
            } catch {
                reject("Recibo \(path.path), workspaceRoot=\(workspaceRoot.path): verificação de reutilização falhou: \(error)")
                continue
            }
        }
        for job in jobs.all().sorted(by: { $0.created > $1.created }) where job.state == .finished && job.steps == [.buildOnly]
            && job.recipe.id == recipe.id && job.request.localAPKVariantID == variant.id
            && job.toolchainCommit == toolchain.commit() && job.request.localAssetsSHA256 == currentAssetsHash
            && (requestedRuntime == nil || Self.runtimeCompatible(job.request, with: requestedRuntime!)) {
            do {
            let bundle = job.request.bundleId ?? Toolchain.defaultBundleId(target: KleptonRecipeCompatibility.resolve(recipe).toolchain.target)
            let jobData = try Data(contentsOf: jobs.url(job.id))
            let logData = try Data(contentsOf: jobs.directory.appendingPathComponent(job.id + ".log"))
            let provenance = try validatedLegacyProvenance(job: job, jobData: jobData, logData: logData,
                appPath: nil, recipe: recipe, variant: variant, toolchain: toolchain,
                jobs: jobs, installations: legacyInstallations, variantStore: variantStore)
            let searchDiagnostics = BuildRecoveryDiagnosticBuffer()
            if let found = try ReusableBuild.find(jobs: jobs, workspaceRoot: workspaceRoot, recipe: recipe,
                request: job.request, bundleID: bundle, apkHash: variant.sha256, toolchain: toolchain,
                report: verifierReport(jobID: job.id, buffer: searchDiagnostics),
                verifiedLegacyManifest: provenance.map(VerifiedLegacyBuildManifest.init)) {
                try validateLegacyWorkspace(provenance, artifact: found, recipe: recipe,
                    installations: legacyInstallations)
                do {
                    try save(LocalBuildReceipt(jobData: jobData, logData: logData, artifact: found,
                                               legacyProvenance: provenance, variant: variant))
                } catch {
                    reject("Job \(job.id), recibo \(directory.appendingPathComponent(job.id + ".json").path): não foi possível gravar a evidência validada sem substituir dados existentes: \(error)")
                    continue
                }
                return (found, job)
            } else {
                recordNoMatch(jobID: job.id, diagnostics: searchDiagnostics.snapshot())
            }
            } catch {
                reject("Job \(job.id), workspaceRoot=\(workspaceRoot.path), arquivo de Job=\(jobs.url(job.id).path): verificação do artefato/recibo falhou: \(error)")
                continue
            }
        }
        let target = KleptonRecipeCompatibility.resolve(recipe).toolchain.target
        let folders = (try? FileManager.default.contentsOfDirectory(at: workspaceRoot, includingPropertiesForKeys: nil)) ?? []
        if folders.contains(where: { $0.lastPathComponent.hasPrefix(target + "-") }) {
            let diagnostics = rejectionBuffer.snapshot()
            let details = diagnostics.isEmpty
                ? "Nenhuma rejeição específica foi retornada pelos validadores. workspaceRoot=\(workspaceRoot.path)."
                : "\nDiagnósticos de rejeição (Job/recibo, caminho e verificação):\n" + diagnostics.joined(separator: "\n")
            throw LocalBuildRecoveryFailure("Há uma compilação preservada, mas faltam evidências verificáveis. Nenhum Prepare, Build only ou recompilação foi iniciado.\(details)")
        }
        return nil
    }

    static func runtimeCompatible(_ stored: InstallRequest, with requested: InstallRequest) -> Bool {
        (requested.coreMods == nil || requested.coreMods == (stored.coreMods ?? false))
            && (requested.controllerMode == nil || requested.controllerMode == (stored.controllerMode ?? .standard))
            && (requested.frameGeneration == nil || requested.frameGeneration == (stored.frameGeneration ?? .off))
            && (requested.surrealSDK == nil || requested.surrealSDK == (stored.surrealSDK ?? .verified))
            && (requested.surrealSupport != true || stored.surrealSupport != false)
            && (requested.surrealSupport != false || stored.surrealSupport == false)
            && (requested.experimental == nil || (requested.experimental ?? false) == (stored.experimental ?? false))
            && (requested.metalFX == nil || (requested.metalFX ?? false) == (stored.metalFX ?? false))
            && (requested.metalFX != true || requested.resolution == stored.resolution)
            && (requested.xrPrediction == nil || (requested.xrPrediction ?? false) == (stored.xrPrediction ?? false))
            && (requested.localAssetsSHA256 == nil || requested.localAssetsSHA256 == stored.localAssetsSHA256)
    }

    private func validatedLegacyProvenance(job: Job, jobData: Data, logData: Data, appPath: String?,
        recipe: Recipe, variant: LocalAPKVariant, toolchain: Toolchain, jobs: JobStore,
        installations: [LocalAPKInstallation], variantStore: LocalAPKVariantStore?) throws -> LocalBuildLegacyProvenance? {
        let candidates = installations.filter { $0.legacyRecovery?.buildJobID == job.id }
        guard !candidates.isEmpty else { return nil }
        guard candidates.count == 1, let installation = candidates.first,
              let build = installation.build, let legacy = installation.legacyRecovery,
              installation.functionalityStatus != nil, installation.revokedAt == nil,
              installation.jobID == legacy.installationJobID,
              installation.variantID == variant.id, installation.sha256 == variant.sha256,
              installation.size == variant.size, installation.package == variant.package,
              installation.versionCode == variant.versionCode,
              variant.recipeID == recipe.id, variant.recipeVersionCode == recipe.versionCode,
              variant.package == recipe.package, variant.versionCode == String(recipe.versionCode),
              job.recipe.id == recipe.id, job.recipe.package == recipe.package,
              job.recipe.versionCode == recipe.versionCode,
              job.request.localAPKVariantID == variant.id, job.request.bundleId == installation.bundleID,
              job.request.team == installation.team, job.request.device == installation.deviceID,
              job.toolchainCommit == toolchain.commit(),
              installation.toolchain == "\(toolchain.version())-\(toolchain.commit())",
              job.updated <= installation.date,
              job.request.localWorkspaceRoot.map({ URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path })
                == workspaceRoot.resolvingSymlinksInPath().standardizedFileURL.path,
              build.recipeSHA256 == (try LocalAPKBuildEvidence.recipeHash(recipe)),
              build.assetsSHA256 == (try LocalAPKBuildEvidence.assetsHash(variant)),
              build.unsignedBuildSHA256.count == 64,
              build.unsignedBuildSHA256.allSatisfy(\.isHexDigit),
              legacy.sourceHashes[legacy.unsignedApp.resolvingSymlinksInPath().standardizedFileURL.path] == build.unsignedBuildSHA256,
              legacy.originalReceiptSHA256.count == 64,
              legacy.originalReceiptSHA256.allSatisfy(\.isHexDigit),
              legacy.buildJobID == job.id else {
            throw LocalAPKVariantError.invalidRecord("A associação legada do Build only é ambígua ou incompleta.")
        }
        let jobHash = Hashing.sha256(of: jobData), logHash = Hashing.sha256(of: logData)
        let historicalAppPath = legacy.unsignedApp.resolvingSymlinksInPath().standardizedFileURL.path
        guard legacy.sourceHashes[jobs.url(job.id).path] == jobHash,
              legacy.sourceHashes[jobs.directory.appendingPathComponent(job.id + ".log").path] == logHash,
              let log = String(data: logData, encoding: .utf8),
              log.contains(historicalAppPath) else {
            throw LocalAPKVariantError.invalidRecord("Job/log não correspondem aos hashes arquivados da instalação.")
        }
        if let appPath {
            guard URL(fileURLWithPath: appPath).resolvingSymlinksInPath().standardizedFileURL.path == historicalAppPath else {
                throw LocalAPKVariantError.invalidRecord("O caminho do app diverge da evidência histórica.")
            }
        }
        if let variantStore {
            let validated = try variantStore.validated(id: variant.id, for: recipe,
                                                       verifyAssetHashes: false, verifyAPKHash: true)
            let metadata = variantStore.root.appendingPathComponent("\(recipe.id)-\(recipe.versionCode)/\(variant.id).json")
            let metadataData = try Data(contentsOf: metadata)
            let stored = try JSONDecoder().decode(LocalAPKVariant.self, from: metadataData)
            let apk = variantStore.root.appendingPathComponent(variant.relativePath)
            guard validated.variant == variant, stored == variant,
                  legacy.sourceHashes[metadata.path] == Hashing.sha256(of: metadataData),
                  legacy.sourceHashes[apk.path] == variant.sha256 else {
                throw LocalAPKVariantError.invalidRecord("Metadados ou hash do APK divergem da proveniência histórica.")
            }
        }
        return LocalBuildLegacyProvenance(installation: installation, buildJobSHA256: jobHash,
            buildLogSHA256: logHash, manifestSHA256: build.unsignedBuildSHA256,
            recipeSHA256: try LocalAPKBuildEvidence.recipeHash(recipe), variant: variant,
            appPath: legacy.unsignedApp.resolvingSymlinksInPath().standardizedFileURL.path)
    }

    private func validateLegacyWorkspace(_ provenance: LocalBuildLegacyProvenance?, artifact: ReusableBuild,
        recipe: Recipe, installations: [LocalAPKInstallation]) throws {
        guard let provenance else { return }
        guard let installation = installations.first(where: { $0.id == provenance.installationReceiptID }),
              let legacy = installation.legacyRecovery,
              artifact.app.resolvingSymlinksInPath().standardizedFileURL.path == provenance.appPath,
              artifact.sourceJobID == provenance.buildJobID,
              artifact.bundleID == provenance.bundleID,
              try LocalAPKBuildEvidence.digest(artifact.files) == provenance.manifestSHA256 else {
            throw LocalAPKVariantError.invalidRecord("O manifesto atual não corresponde ao hash histórico preservado.")
        }
        let target = KleptonRecipeCompatibility.resolve(recipe).toolchain.target
        let paths = [artifact.workspace.appendingPathComponent("build-only.log"),
                     artifact.workspace.appendingPathComponent("toolchain.json"),
                     artifact.workspace.appendingPathComponent(target).appendingPathComponent(".qi-prepared")]
        for path in paths {
            guard let expected = legacy.sourceHashes[path.path],
                  Hashing.sha256(of: try Data(contentsOf: path)) == expected else {
                throw LocalAPKVariantError.invalidRecord("Log, manifesto da toolchain ou stamp diverge da evidência histórica: \(path.lastPathComponent).")
            }
        }
    }
}
