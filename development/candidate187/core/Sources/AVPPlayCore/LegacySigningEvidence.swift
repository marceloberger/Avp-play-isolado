import Foundation

/// Validates a pre-learning local install whose signing record predates `assetsSHA256`.
/// This proves the APK/build/install association; it never claims that the game was played.
public enum LegacySigningEvidence {
    private struct PreparationValidation: Decodable {
        let schema: Int
        let recipe: String
        let metadata: String
        let files: [SHA256FileCache.Identity]
    }

    /// Reads only local metadata, Jobs, receipts, logs and the native app bundle. It never reads external game assets.
    public static func verify(signing: SigningRecord, variant: LocalAPKVariant, recipe: Recipe,
                              variants: LocalAPKVariantStore, jobs: JobStore, store: ContentStore,
                              verifyNativeFiles: Bool = true) throws -> String {
        func require(_ value: Bool, _ reason: String) throws {
            guard value else { throw LocalAPKVariantError.invalidRecord("Evidência legada insuficiente: " + reason) }
        }
        func canonical(_ path: String?) -> String? {
            guard let path, path.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        }
        try require(signing.buildEvidence?.assetsSHA256 == nil, "o registro não é legado.")
        try require(variant.recipeID == recipe.id && variant.recipeVersionCode == recipe.versionCode
            && variant.package == recipe.package && variant.versionCode == String(recipe.versionCode), "variante diverge da receita.")
        let metadataURL = variants.root.appendingPathComponent("\(recipe.id)-\(recipe.versionCode)/\(variant.id).json")
        let metadata = try Data(contentsOf: metadataURL)
        let stored = try JSONDecoder().decode(LocalAPKVariant.self, from: metadata)
        try require(stored == variant, "metadados da variante foram alterados.")
        let prepURL = variants.root.appendingPathComponent(".preparation-validations/\(variant.id).json")
        let prep = try JSONDecoder().decode(PreparationValidation.self, from: Data(contentsOf: prepURL))
        try require(prep.schema == 1 && prep.metadata == Hashing.sha256(of: metadata)
            && prep.recipe == LocalAPKBuildEvidence.recipeHash(KleptonRecipeCompatibility.resolve(recipe))
            && prep.files.count == 1 + (variant.assets ?? []).count, "validação original da variante está ausente ou não corresponde aos metadados atuais.")

        guard let bundle = signing.bundleId, SigningRecord.isSafeBundleId(bundle),
              let request = signing.installedConfiguration,
              let variantStorePath = signing.localVariantStorePath,
              let toolchainPath = signing.toolchainPath,
              let device = request.device, !device.isEmpty,
              request.localAPKVariantID == variant.id, request.bundleId == bundle,
              request.team == signing.team, request.localVariantStorePath != nil,
              canonical(request.localVariantStorePath) == canonical(variantStorePath),
              canonical(request.toolchain) == canonical(toolchainPath),
              let buildEvidence = signing.buildEvidence else {
            throw LocalAPKVariantError.invalidRecord("Evidência legada insuficiente: identidade local incompleta.")
        }
        try require(canonical(variantStorePath) == canonical(variants.root.path), "biblioteca local divergente.")
        try require(buildEvidence.recipeSHA256 == LocalAPKBuildEvidence.recipeHash(recipe), "hash da receita diverge.")
        for hash in [buildEvidence.signedBuildSHA256, buildEvidence.unsignedBuildSHA256] {
            try require(hash.count == 64 && hash.allSatisfy(\.isHexDigit), "hash do build inválido.")
        }

        let allJobs = jobs.all()
        let installs = allJobs.filter { job in
            job.state == .finished && job.completed == [.fetch, .build] && job.steps == [.fetch, .build]
                && job.request.automaticLocalInstall == true && job.request.reuseBuildOnly == true
                && job.request.localAPKVariantID == variant.id && job.request.bundleId == bundle
                && job.request.device == device && job.request.team == signing.team
                && canonical(job.request.localVariantStorePath) == canonical(variants.root.path)
                && canonical(job.request.toolchain) == canonical(toolchainPath)
                && job.updated == signing.installed
                && (try? LocalAPKBuildEvidence.recipeHash(job.recipe)) == (try? LocalAPKBuildEvidence.recipeHash(recipe))
        }
        try require(installs.count == 1, "Job de instalação concluído ausente ou ambíguo.")
        let install = installs[0]
        let installLog = try Data(contentsOf: jobs.directory.appendingPathComponent(install.id + ".log"))
        guard let installText = String(data: installLog, encoding: .utf8) else {
            throw LocalAPKVariantError.invalidRecord("Log da instalação ilegível.")
        }
        try require(installText.contains("App existente assinado e instalação confirmada."), "log não confirma assinatura e instalação.")

        let workspaceRootPath = install.request.localWorkspaceRoot
        guard let workspaceRootPath, canonical(workspaceRootPath) != nil else {
            throw LocalAPKVariantError.invalidRecord("Raiz do workspace não registrada.")
        }
        let workspaceRoot = URL(fileURLWithPath: workspaceRootPath)
        let recovery = LocalBuildRecovery(workspaceRoot: workspaceRoot)
        let receiptFiles = (try FileManager.default.contentsOfDirectory(at: recovery.directory, includingPropertiesForKeys: nil))
            .filter { $0.pathExtension == "json" }
        var matches: [(LocalBuildReceipt, Job)] = []
        var rejected: [String] = []
        for url in receiptFiles {
            let receipt = try JSONDecoder().decode(LocalBuildReceipt.self, from: Data(contentsOf: url))
            let build = try receipt.job()
            guard build.recipe.id == recipe.id, build.request.localAPKVariantID == variant.id else { continue }
            guard build.request.bundleId == install.request.preservedBuildBundleID,
                  receipt.artifact.bundleID == build.request.bundleId else { rejected.append("identidade do build preserved divergente"); continue }
            guard build.toolchainCommit == install.toolchainCommit else { rejected.append("toolchain divergente"); continue }
            guard (try? LocalAPKBuildEvidence.recipeHash(build.recipe)) == (try? LocalAPKBuildEvidence.recipeHash(recipe)) else { rejected.append("receita do Build only divergente"); continue }
            guard installText.contains("Reutilizando app do Job \(build.id). Nenhuma compilação será executada.") else { rejected.append("log de instalação não referencia \(build.id)"); continue }
            guard let receiptWorkspace = canonical(receipt.artifact.workspace.path),
                  receiptWorkspace.hasPrefix(canonical(workspaceRoot.path)! + "/") else { rejected.append("workspace do artefato divergente"); continue }
            guard try LocalAPKBuildEvidence.digest(receipt.artifact.files) == buildEvidence.unsignedBuildSHA256 else { rejected.append("hashes do Build only divergem do registro de assinatura"); continue }
            // If the archived Job still exists, it must be byte-identical to the receipt.
            let jobURL = jobs.directory.appendingPathComponent(build.id + ".json")
            let logURL = jobs.directory.appendingPathComponent(build.id + ".log")
            if FileManager.default.fileExists(atPath: jobURL.path) {
                guard try Data(contentsOf: jobURL) == receipt.jobData else { rejected.append("Job em disco diverge do recibo"); continue }
            }
            if FileManager.default.fileExists(atPath: logURL.path) {
                guard try Data(contentsOf: logURL) == receipt.logData else { rejected.append("log em disco diverge do recibo"); continue }
            }
            matches.append((receipt, build))
        }
        try require(matches.count == 1, "recibo e Job Build only vinculados à instalação ausentes ou ambíguos. \(rejected.joined(separator: "; "))")
        let (receipt, build) = matches[0]
        guard let buildText = String(data: receipt.logData, encoding: .utf8) else {
            throw LocalAPKVariantError.invalidRecord("Log do Build only ilegível.")
        }
        try require(buildText.contains(receipt.artifact.app.path) || buildText.contains(receipt.artifact.app.resolvingSymlinksInPath().path),
                    "log do Build only não aponta para o artefato preservado.")
        let app = receipt.artifact.app
        let appRoot = app.resolvingSymlinksInPath().standardizedFileURL.path
        try require(appRoot.hasPrefix(workspaceRoot.resolvingSymlinksInPath().standardizedFileURL.path + "/"), "artefato fora do workspace.")
        let target = KleptonRecipeCompatibility.resolve(recipe).toolchain.target
        let info = try ReusableBuild.infoPlist(app.appendingPathComponent("Info.plist"))
        let compileLog = try String(contentsOf: receipt.artifact.workspace.appendingPathComponent("build-only.log"), encoding: .utf8)
        try require(info["CFBundleIdentifier"] as? String == build.request.bundleId
            && build.request.bundleId == install.request.preservedBuildBundleID
            && ReusableBuild.matchesTarget(info: info, recipe: recipe, buildLog: compileLog)
            && (info["CFBundleSupportedPlatforms"] as? [String])?.contains("XROS") == true, "produto não corresponde ao app instalado.")
        let stamp = try String(contentsOf: receipt.artifact.workspace.appendingPathComponent(target + "/.qi-prepared"), encoding: .utf8)
        try require(stamp.hasPrefix("local:\(variant.id):\(variant.sha256) \(variant.versionCode) "), "stamp não vincula o build ao APK exato.")
        try require(compileLog.contains("** BUILD SUCCEEDED **") && compileLog.contains("[exit 0]"), "build não tem resultado de sucesso.")
        if verifyNativeFiles {
            try require(try ReusableBuild.inventory(app) == receipt.artifact.files, "arquivos nativos atuais divergem dos 47 hashes preservados.")
        }
        // `build` is intentionally used above to validate a frozen completed Job, not to execute work.
        _ = build
        return install.id
    }
}
