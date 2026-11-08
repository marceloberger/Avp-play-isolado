import Foundation

/// Narrow, evidence-bound rollout for the audited Laser Matrix artifact. This does
/// not relax Installer's general experimental-recipe block or promote a recipe.
public enum ExperimentalInstallation168 {
    struct Specification: Decodable {
        let revision: String
        let sourceJobID: String
        let apkSHA256: String
        let package: String
        let target: String
        let versionCode: Int
        let sourceAppFiles: [String: String]
        let correctedAppFiles: [String: String]
        let dataFiles: [String: String]
        let entitlementsSHA256: String
    }
    public struct Plan {
        public let artifact: ReusableBuild
        public let sourceJob: Job
        public let dataBytes: Int64
        public let dataFileCount: Int
        let entries: [InstallationContent.Entry]
        let specification: Specification
    }
    static func specification() throws -> Specification {
        guard let url = Bundle.module.url(forResource: "laser-matrix-tls168", withExtension: "json") else {
            throw RecipeError.invalid("Evidência TLS 168 ausente; instalação experimental bloqueada.")
        }
        return try JSONDecoder().decode(Specification.self, from: Data(contentsOf: url))
    }
    static func verifyApp(_ app: URL, expected: [String: String]) throws {
        guard try ReusableBuild.inventory(app) == expected else {
            throw RecipeError.invalid("O app diverge do manifesto TLS 168; nenhum fallback ou recompilação autorizado.")
        }
    }
    static func confinedFile(_ root: URL, relative: String, digest: String) throws -> URL {
        guard Recipe.isSafeRelativePath(relative), !relative.isEmpty else { throw RecipeError.invalid("Caminho experimental inválido") }
        let file = root.appendingPathComponent(relative)
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard file.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(base),
              try Hashing.sha256(of: file) == digest else {
            throw RecipeError.invalid("Arquivo experimental ausente, inseguro ou alterado: \(relative)")
        }
        return file
    }
    static func destination(for path: String, target: String) throws -> String {
        guard Recipe.isSafeName(target), Recipe.isSafeRelativePath(path),
              path == target + ".apk" || path == target + "/AndroidManifest.xml"
                || path == target + "/apktool.yml" || path.hasPrefix(target + "/assets/") else {
            throw RecipeError.invalid("Destino de dados experimental não permitido: \(path)")
        }
        return "Documents/" + path
    }
    public static func makePlan(job: Job, workspace: URL, correctedApp: URL) throws -> Plan {
        let spec = try specification()
        try job.recipe.validateForJob()
        guard job.id == spec.sourceJobID, job.state == .finished, job.steps == [.buildOnly],
              job.completed == [.buildOnly], job.toolchainCommit == "a61188d",
              job.recipe.package == spec.package, job.recipe.versionCode == spec.versionCode,
              job.recipe.toolchain.target == spec.target,
              job.recipe.localExperimental?.apkSHA256 == spec.apkSHA256,
              job.recipe.localExperimental?.associatedFiles.isEmpty == true,
              job.recipe.localExperimental?.engine == .unity,
              job.recipe.localExperimental?.entrypoint == "libmain" else {
            throw RecipeError.invalid("Receita/Job não corresponde à evidência Laser Matrix TLS 168. Outras receitas experimentais continuam bloqueadas.")
        }
        let tc = try Toolchain(root: workspace)
        guard tc.version() == 824, tc.commit() == "a61188d" else { throw RecipeError.invalid("Workspace não é Klepton 824 a61188d") }
        let log = try String(contentsOf: workspace.appendingPathComponent("build-only.log"), encoding: .utf8)
        guard log.contains("** BUILD SUCCEEDED **"), log.contains("[exit 0]"),
              let uuid = UUID(uuidString: String(workspace.lastPathComponent.suffix(36))) else {
            throw RecipeError.invalid("Não há evidência do Build only original concluído")
        }
        let product = "KleptonX8840783592704373.app"
        let source = workspace.appendingPathComponent("visionos/build/avpplay-build-only/\(uuid.uuidString.lowercased())/DerivedData/Build/Products/Debug-xros/\(product)")
        guard correctedApp.resolvingSymlinksInPath() != source.resolvingSymlinksInPath() else {
            throw RecipeError.invalid("Use uma cópia corrigida; o artefato original deve permanecer intacto")
        }
        try verifyApp(source, expected: spec.sourceAppFiles)
        try verifyApp(correctedApp, expected: spec.correctedAppFiles)
        _ = try confinedFile(workspace, relative: "visionos/Klepton.entitlements", digest: spec.entitlementsSHA256)
        let info = try ReusableBuild.infoPlist(correctedApp.appendingPathComponent("Info.plist"))
        guard let bundle = info["CFBundleIdentifier"] as? String, bundle == job.request.bundleId,
              info["MinimumOSVersion"] as? String == "26.0" else { throw RecipeError.invalid("Identidade/plataforma do app divergente") }
        let entries = try spec.dataFiles.sorted(by: { $0.key < $1.key }).map { path, hash in
            let file = try confinedFile(workspace, relative: path, digest: hash)
            return InstallationContent.Entry(source: file, destination: try destination(for: path, target: spec.target),
                                              size: ContentStore.fileSize(file) ?? 0, sha256: hash)
        }
        guard entries.count == 39, entries.allSatisfy({ $0.size > 0 }) else { throw RecipeError.invalid("Inventário de dados incompleto") }
        return Plan(artifact: ReusableBuild(app: correctedApp, workspace: workspace, sourceJobID: job.id,
                    bundleID: bundle, files: spec.correctedAppFiles), sourceJob: job,
                    dataBytes: entries.reduce(0) { $0 + $1.size }, dataFileCount: entries.count,
                    entries: entries, specification: spec)
    }
    static func requireAuthorizedInputs(_ plan: Plan) throws {
        guard let variantID = plan.sourceJob.request.localAPKVariantID,
              let registryPath = plan.sourceJob.request.localVariantStorePath else {
            throw RecipeError.invalid("Variante local explícita ausente")
        }
        let registry = LocalAPKVariantStore(root: URL(fileURLWithPath: registryPath))
        let selected = try registry.validated(id: variantID, for: plan.sourceJob.recipe, forceFull: true)
        try LocalAPKLearningStore(variants: registry).requireAuthorized(selected.variant, recipe: plan.sourceJob.recipe)
        guard selected.variant.sha256 == plan.specification.apkSHA256,
              try AndroidAPKSignature.inspect(selected.apk).verified else {
            throw RecipeError.invalid("APK autorizado/assinatura Android não confirmado")
        }
        try verifyApp(plan.artifact.app, expected: plan.specification.correctedAppFiles)
        for (path, hash) in plan.specification.dataFiles {
            _ = try confinedFile(plan.artifact.workspace, relative: path, digest: hash)
        }
        _ = try confinedFile(plan.artifact.workspace, relative: "visionos/Klepton.entitlements", digest: plan.specification.entitlementsSHA256)
    }
    static func requireNoReplacement(_ apps: [InstalledApp], bundle: String) throws {
        guard !apps.contains(where: { $0.bundleIdentifier == bundle }) else {
            throw RecipeError.invalid("Este Bundle ID já está instalado. O fluxo experimental 168 recusa substituição; nenhum app existente será sobrescrito.")
        }
    }
    static func requireDevice(_ device: Device) throws {
        let major = Int(device.osVersion.split(separator: ".").first ?? "") ?? 0
        guard device.paired, device.reachable, device.developerMode, major >= 26 else {
            throw RecipeError.invalid("Vision Pro pareado, acessível, em Developer Mode e visionOS 26+ obrigatório")
        }
    }
    /// Explicit CLI opt-in only. Never called by Prepare, Build only, startup or
    /// generic Installer. Replaces nothing, never compiles, creates no Job, never launches.
    public static func install(_ plan: Plan, deviceID: String, team: String, outputRoot: URL,
                               report: @escaping @Sendable (String) -> Void = { _ in }) throws {
        try RuntimePolicy177.requireArtifact(plan.artifact)
        guard !deviceID.isEmpty, !team.isEmpty else { throw RecipeError.invalid("Equipe e UDID explícitos obrigatórios") }
        guard let lock = ProcessLock.acquire(ProcessLock.installURL) else {
            throw RecipeError.invalid("Outra operação está ativa. Nenhuma interferência autorizada.")
        }
        defer { lock.release() }
        guard !JobStore(directory: JobStore.defaultDirectory).all().contains(where: { $0.state == .running || $0.state == .waiting }) else {
            throw RecipeError.invalid("Há Jobs ativos/na fila; instalação experimental recusada sem interferência.")
        }
        try requireAuthorizedInputs(plan)
        let control = DeviceControl()
        let device = try control.pick(udid: deviceID)
        try requireDevice(device)
        try requireNoReplacement(control.apps(device: device), bundle: plan.artifact.bundleID)
        let signed = try ExistingAppSigner.sign(plan.artifact, team: team, device: device, outputRoot: outputRoot, preserveAllRequestedEntitlements: true, report: report)
        // No transfer or installation before the signed copy and profile pass the existing signer.
        try requireAuthorizedInputs(plan)
        let current = try control.pick(udid: deviceID)
        try requireDevice(current)
        try requireNoReplacement(control.apps(device: current), bundle: plan.artifact.bundleID)
        try RuntimePolicy177.requireArtifact(plan.artifact)
        try control.install(signed.app, device: current)
        let installed = try control.installedApp(device: current, bundle: plan.artifact.bundleID, report: report)
        guard let scope = installed.url else { throw RecipeError.invalid("Container instalado não confirmado") }
        func confirm() throws {
            guard try control.installedApp(device: current, bundle: plan.artifact.bundleID, report: report).url == scope else {
                throw RecipeError.invalid("Identidade do container mudou; transferência bloqueada")
            }
        }
        let receipts = signed.app.deletingLastPathComponent().appendingPathComponent("data-verification.json")
        try InstallationContent.sync(plan.entries, container: .init(stat: { path in
            try confirm()
            return try control.checkedFiles(device: current, bundle: plan.artifact.bundleID,
                subdirectory: (path as NSString).deletingLastPathComponent)
                .first { $0.relativePath == (path as NSString).lastPathComponent }
        }, fetch: { path, local in
            try confirm()
            try control.copy(from: current, bundle: plan.artifact.bundleID, source: path, to: local)
        }, put: { source, path in
            try confirm()
            guard let entry = plan.entries.first(where: { $0.destination == path }),
                  try Hashing.sha256(of: source) == entry.sha256 else { throw RecipeError.invalid("Dados mudaram antes da cópia") }
            try control.copy(source, to: current, bundle: plan.artifact.bundleID, destination: path)
        }), receipts: receipts, report: report)
        try confirm()
        report("Instalação experimental e 39 arquivos verificados. Nenhum lançamento automático. Job e build originais preservados.")
    }
}
