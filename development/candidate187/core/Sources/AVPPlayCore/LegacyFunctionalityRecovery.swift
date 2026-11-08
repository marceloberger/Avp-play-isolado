import Foundation
import CryptoKit

public struct LegacyFunctionalityEvidence: Codable, Sendable, Equatable {
    public var verifiedAt: Date
    public var originalReceiptSHA256: String
    public var installationJobID: String
    public var buildJobID: String
    public var unsignedApp: URL
    public var signedApp: URL
    public var sourceHashes: [String: String]
}

/// Recovers evidence, never a successful play test. All filesystem access is read-only except temporary
/// extraction of the public signing certificate. No device, compiler, signing or provisioning operation.
public enum LegacyFunctionalityRecovery {
    public static func prepare(receipt: LocalAPKInstallation, variant: LocalAPKVariant, recipe: Recipe,
                               variants: LocalAPKVariantStore, store: ContentStore, jobs: JobStore,
                               base: URL = DataLocation.base) throws -> LocalAPKInstallation {
        try prepare(receipt: receipt, variant: variant, recipe: recipe, variants: variants, store: store,
                    jobs: jobs, base: base, verifySignature: verifySignature)
    }

    static func prepare(receipt: LocalAPKInstallation, variant: LocalAPKVariant, recipe: Recipe,
                        variants: LocalAPKVariantStore, store: ContentStore, jobs: JobStore, base: URL,
                        verifySignature: (URL, LocalAPKInstallation) throws -> Void) throws -> LocalAPKInstallation {
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw LocalAPKVariantError.invalidRecord("Instalação anterior: " + message) }
        }
        try Task.checkCancellation()
        try require(receipt.build == nil && receipt.configuration == nil && receipt.confirmedAt == nil,
                    "o recibo não é um registro legado sem configuração.")
        try require(receipt.variantID == variant.id && receipt.sha256 == variant.sha256 && receipt.size == variant.size
            && receipt.package == variant.package && receipt.versionCode == variant.versionCode
            && variant.recipeID == recipe.id && variant.recipeVersionCode == recipe.versionCode
            && variant.package == recipe.package && variant.versionCode == String(recipe.versionCode), "variante, pacote ou versão divergentes.")
        try require(Recipe.isSafeName(variant.id) && Recipe.isSafeName(recipe.id), "identificador local inválido.")
        var sources: [String: String] = [:]
        func capture(_ url: URL) throws -> Data {
            let before = try SHA256FileCache.identity(url)
            let data = try Data(contentsOf: url)
            try require(try SHA256FileCache.identity(url) == before, "arquivo alterado durante a leitura: \(url.lastPathComponent)")
            sources[url.path] = Hashing.sha256(of: data)
            return data
        }
        let recorded = try LocalAPKLearningStore(variants: variants).load(recipe).installations.first { $0.id == receipt.id }
        try require(recorded == receipt, "o recibo foi removido ou alterado.")
        let relative = variant.relativePath.split(separator: "/", omittingEmptySubsequences: false)
        try require(!variant.relativePath.hasPrefix("/") && !relative.contains("..") && !relative.contains(""), "caminho do APK inválido.")
        let metadata = variants.root.appendingPathComponent("\(recipe.id)-\(recipe.versionCode)/\(variant.id).json")
        let storedVariant = try JSONDecoder().decode(LocalAPKVariant.self, from: capture(metadata))
        try require(storedVariant == variant, "os metadados da variante mudaram.")
        let apk = variants.root.appendingPathComponent(variant.relativePath)
        try require(apk.resolvingSymlinksInPath().path.hasPrefix(variants.root.resolvingSymlinksInPath().path + "/"), "APK fora da biblioteca.")
        let apkData = try capture(apk)
        try require(apkData.count == variant.size && Hashing.sha256(of: apkData) == variant.sha256, "SHA-256/tamanho do APK diverge do recibo.")
        let inspected = try ApkUnpacker().inspect(apk: apk)
        try require(inspected.package == receipt.package && inspected.versionCode == receipt.versionCode
            && inspected.versionName == variant.versionName && inspected.architectures.contains("arm64-v8a"), "identidade Android divergente.")

        let recipeHash = try LocalAPKBuildEvidence.recipeHash(recipe)
        let installs = try jobs.all().filter {
            guard $0.state == .finished && $0.completed.contains(.build) && $0.completed.contains(.stage)
                && $0.request.localAPKVariantID == variant.id && $0.request.bundleId == receipt.bundleID
                && $0.request.device == receipt.deviceID && $0.request.team == receipt.team
                && $0.created <= receipt.date && receipt.date <= $0.updated else { return false }
            return try LocalAPKBuildEvidence.recipeHash($0.recipe) == recipeHash
        }
        try require(installs.count == 1, "Job de instalação concluído ausente ou ambíguo.")
        let install = installs[0]
        _ = try capture(jobs.url(install.id))
        let installLog = String(decoding: try capture(jobs.directory.appendingPathComponent(install.id + ".log")), as: UTF8.self)
        try require(installLog.contains("App existente assinado e instalação confirmada."), "o log não confirma a instalação do build reutilizado.")
        let builds = try jobs.all().filter {
            guard $0.state == .finished && $0.steps == [.buildOnly] && $0.completed == [.buildOnly]
                && $0.request.localAPKVariantID == variant.id && $0.toolchainCommit == install.toolchainCommit
                && $0.updated <= receipt.date
                && installLog.contains("Reutilizando app do Job \($0.id). Nenhuma compilação será executada.") else { return false }
            return try LocalAPKBuildEvidence.recipeHash($0.recipe) == recipeHash
        }
        try require(builds.count == 1, "Job Build only de origem ausente ou ambíguo.")
        let build = builds[0]
        _ = try capture(jobs.url(build.id))
        let buildLog = String(decoding: try capture(jobs.directory.appendingPathComponent(build.id + ".log")), as: UTF8.self)

        let signingURLs = [SigningRecord.url(store: store, recipe: recipe, bundleId: receipt.bundleID),
                           SigningRecord.url(store: store, recipe: recipe)].compactMap { $0 }
        let matchingSigning = signingURLs.filter { url in
            guard let record = SigningRecord.read(url) else { return false }
            return record.bundleId == receipt.bundleID && record.installed == receipt.date
                && record.localAPKVariantID == receipt.variantID && record.team == receipt.team
        }
        try require(!matchingSigning.isEmpty, "registro de assinatura com a mesma data/variante/Bundle ID ausente.")
        for url in matchingSigning { _ = try capture(url) }
        let signingRecords = matchingSigning.compactMap(SigningRecord.read)
        try require(Set(signingRecords.compactMap(\.toolchainPath)).count == 1, "caminho da toolchain ausente ou ambíguo no registro de assinatura.")
        let installedToolchain = signingRecords[0].toolchainPath!

        let workspaceRoot = build.request.localWorkspaceRoot.map { URL(fileURLWithPath: $0) } ?? base.appendingPathComponent("build-only")
        let workspaces = try FileManager.default.contentsOfDirectory(at: workspaceRoot, includingPropertiesForKeys: nil)
        var unsigned: [(app: URL, workspace: URL, files: [String: String])] = []
        for workspace in workspaces {
            let id = String(workspace.lastPathComponent.suffix(36))
            guard UUID(uuidString: id) != nil else { continue }
            let products = workspace.appendingPathComponent("visionos/build/avpplay-build-only/\(id)/DerivedData/Build/Products/Debug-xros")
            for app in (try? FileManager.default.contentsOfDirectory(at: products, includingPropertiesForKeys: nil)) ?? []
                where app.pathExtension == "app" {
                let loggedPath = workspaceRoot.appendingPathComponent(workspace.lastPathComponent)
                    .appendingPathComponent("visionos/build/avpplay-build-only/\(id)/DerivedData/Build/Products/Debug-xros")
                    .appendingPathComponent(app.lastPathComponent).path
                guard buildLog.contains(app.path) || buildLog.contains(loggedPath) else { continue }
                try require(app.resolvingSymlinksInPath().path.hasPrefix(workspaceRoot.resolvingSymlinksInPath().path + "/"), "build fora do workspace registrado.")
                let info = try ReusableBuild.infoPlist(app.appendingPathComponent("Info.plist"))
                let target = KleptonRecipeCompatibility.resolve(recipe).toolchain.target
                try require(info["CFBundleIdentifier"] as? String == receipt.bundleID && info["KLTree"] as? String == target
                    && (info["CFBundleSupportedPlatforms"] as? [String])?.contains("XROS") == true, "Bundle ID, alvo ou plataforma do produto divergentes.")
                let stamp = String(decoding: try capture(workspace.appendingPathComponent(target + "/.qi-prepared")), as: UTF8.self)
                try require(stamp.hasPrefix("local:\(variant.id):\(variant.sha256) \(variant.versionCode) "), "stamp não vincula o build ao APK completo.")
                let compilation = String(decoding: try capture(workspace.appendingPathComponent("build-only.log")), as: UTF8.self)
                try require(compilation.contains("** BUILD SUCCEEDED **") && compilation.contains("[exit 0]"), "log de compilação concluída ausente.")
                let manifest = try JSONSerialization.jsonObject(with: capture(workspace.appendingPathComponent("toolchain.json"))) as? [String: Any]
                guard let version = manifest?["version"] as? Int, let commit = manifest?["commit"] as? String else {
                    throw LocalAPKVariantError.invalidRecord("Manifesto da toolchain incompleto.")
                }
                let components = (info["CFBundleVersion"] as? String)?.split(separator: ".").map(String.init) ?? []
                try require("\(version)-\(commit)" == receipt.toolchain && commit == build.toolchainCommit
                    && components.count >= 2 && components[0] == variant.versionCode && components[1] == String(version), "toolchain/versão do produto divergente.")
                // Metadata (permissions/xattrs) may have changed after the build. Trust the byte comparison
                // with the verified signed copy that must still predate the installation, not unsigned ctime.
                unsigned.append((app, workspace, try ReusableBuild.inventory(app)))
            }
        }
        try require(unsigned.count == 1, "artefato Build only ausente ou ambíguo em \(workspaceRoot.path) para o Job \(build.id).")
        let original = unsigned[0]
        var signed: [(app: URL, files: [String: String])] = []
        for folder in (try? FileManager.default.contentsOfDirectory(at: base.appendingPathComponent("signed-existing"), includingPropertiesForKeys: nil)) ?? [] {
            let app = folder.appendingPathComponent(original.app.lastPathComponent)
            guard FileManager.default.fileExists(atPath: app.path),
                  let info = try? ReusableBuild.infoPlist(app.appendingPathComponent("Info.plist")),
                  info["CFBundleIdentifier"] as? String == receipt.bundleID,
                  let signLog = try? String(contentsOf: folder.appendingPathComponent("sign-existing.log")) else { continue }
            let loggedApp = base.appendingPathComponent("signed-existing").appendingPathComponent(folder.lastPathComponent)
                .appendingPathComponent(app.lastPathComponent)
            guard signLog.contains("/usr/bin/codesign --verify --deep --strict \(app.path)\n\n[exit 0]")
                || signLog.contains("/usr/bin/codesign --verify --deep --strict \(loggedApp.path)\n\n[exit 0]") else { continue }
            let files = try ReusableBuild.inventory(app, unchangedSince: receipt.date.addingTimeInterval(1))
            try LegacySignedBuild.verify(unsigned: original.app, signed: app, unsignedFiles: original.files, signedFiles: files)
            try verifySignature(app, receipt)
            _ = try capture(folder.appendingPathComponent("sign-existing.log"))
            signed.append((app, files))
        }
        try require(signed.count == 1, "cópia assinada verificável ausente ou ambígua.")
        let product = signed[0]
        let info = try ReusableBuild.infoPlist(product.app.appendingPathComponent("Info.plist"))
        var configuration = try configuration(request: install.request, info: info)
        configuration.toolchain = installedToolchain
        // Persist only fields whose source is a product or the frozen installation Job.
        var recovered = receipt
        recovered.gameTitle = recipe.title; recovered.recipeID = recipe.id; recovered.jobID = install.id
        recovered.configuration = configuration
        recovered.build = LocalAPKBuildEvidence(signedBuildSHA256: try LocalAPKBuildEvidence.digest(product.files),
            unsignedBuildSHA256: try LocalAPKBuildEvidence.digest(original.files), recipeSHA256: recipeHash,
            assetsSHA256: try LocalAPKBuildEvidence.assetsHash(variant),
            settings: Dictionary(uniqueKeysWithValues: info.filter { $0.key.hasPrefix("KL") }.map { ("Info." + $0.key, String(describing: $0.value)) }))
        sources[original.app.path] = recovered.build?.unsignedBuildSHA256
        sources[product.app.path] = recovered.build?.signedBuildSHA256
        recovered.legacyRecovery = LegacyFunctionalityEvidence(verifiedAt: Date(),
            originalReceiptSHA256: try LocalAPKBuildEvidence.digest(receipt), installationJobID: install.id,
            buildJobID: build.id, unsignedApp: original.app, signedApp: product.app, sourceHashes: sources)
        return recovered
    }

    static func configuration(request: InstallRequest, info: [String: Any]) throws -> InstallRequest {
        guard let modeString = info["KLControllerModeDefault"] as? String, let mode = ControllerMode(rawValue: modeString),
              let room = info["KLRoomGuardDefault"] as? String, ["0", "1"].contains(room),
              let language = info["KLGameLanguageDefault"] as? String,
              let switches = info["KLTestOn"] as? String, let scale = info["KLRenderScaleDefault"] as? String,
              let percentage = Double(scale), percentage.isFinite, percentage > 0 else {
            throw LocalAPKVariantError.invalidRecord("Configuração essencial ausente no produto: controles, área, idioma, KLTestOn ou escala.")
        }
        let flags = Set(switches.split(separator: ",").map(String.init))
        let experimental = Set(Toolchain.experimentalSwitches)
        guard flags.isSubset(of: experimental.union([Toolchain.metalFXSwitch, Toolchain.xrPredictionSwitch])),
              flags.intersection(experimental).isEmpty || experimental.isSubset(of: flags) else {
            throw LocalAPKVariantError.invalidRecord("Combinação de flags não representável pelo instalador; nenhuma configuração será presumida.")
        }
        var result = request
        result.controllerMode = mode; result.roomMeasuring = room == "1"; result.gameLanguage = language
        result.experimental = experimental.isSubset(of: flags)
        result.metalFX = flags.contains(Toolchain.metalFXSwitch); result.xrPrediction = flags.contains(Toolchain.xrPredictionSwitch)
        result.resolution = result.metalFX == true ? Int((percentage * 100).rounded()) : nil
        result.requireExistingBuildOnResume = nil
        return result
    }

    private static func verifySignature(_ app: URL, receipt: LocalAPKInstallation) throws {
        _ = try ApkUnpacker.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", app.path])
        let profile = try ProvisioningProfileDecoder.decode(Data(contentsOf: app.appendingPathComponent("embedded.mobileprovision")))
        let entitlements = try ApkUnpacker.run(["/usr/bin/codesign", "-d", "--entitlements", ":-", app.path]).data
        let values = profile
        guard let wanted = try PropertyListSerialization.propertyList(from: entitlements, format: nil) as? [String: Any] else {
            throw LocalAPKVariantError.invalidRecord("Perfil ou permissões assinadas ilegíveis.")
        }
        let temporary = DataLocation.temporaryDirectory.appendingPathComponent("legacy-public-certificate-\(UUID())")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let prefix = temporary.appendingPathComponent("certificate")
        _ = try ApkUnpacker.run(["/usr/bin/codesign", "-d", "--extract-certificates=" + prefix.path, app.path])
        let certificate = try Data(contentsOf: temporary.appendingPathComponent("certificate0"))
        let identity = Insecure.SHA1.hash(data: certificate).map { String(format: "%02X", $0) }.joined()
        _ = try ExistingAppSigner.plan(profiles: [.init(path: app.appendingPathComponent("embedded.mobileprovision"),
            data: try Data(contentsOf: app.appendingPathComponent("embedded.mobileprovision")), values: values)],
            team: receipt.team, bundle: receipt.bundleID, device: receipt.deviceID, identity: identity,
            requested: wanted, free: false, now: receipt.date)
    }
}
