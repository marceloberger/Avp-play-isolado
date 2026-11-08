import Foundation

/// Local technical eligibility, never a publisher, ownership or playability assertion.
/// The UI uses the metadata check; Installer must also re-read the selected APK and assets.
public enum LocalExperimentalAdmission {
    public static func requireEligible(recipe: Recipe, variant: LocalAPKVariant) throws {
        guard let metadata = recipe.localExperimental else { return }
        try recipe.validateForJob()
        guard metadata.isValid, metadata.toolchain == ExperimentalRuntime183.klepton850.rawValue,
              recipe.toolchain.minCommit == ExperimentalRuntime183.klepton850.minCommit,
              recipe.toolchain.target == DraftRecipe.genericTarget(appId: metadata.appID),
              recipe.status.playability == "untested", recipe.store.appId == nil,
              recipe.store.steamAppId == nil, recipe.addons == nil, recipe.trees == nil,
              variant.recipeID == recipe.id, variant.recipeVersionCode == recipe.versionCode,
              variant.package == metadata.package, variant.versionCode == String(metadata.versionCode),
              (variant.versionName ?? "") == recipe.versionName,
              variant.size == metadata.apkSize, variant.sha256.lowercased() == metadata.apkSHA256.lowercased(),
              variant.architectures.sorted() == metadata.architectures.sorted(),
              variant.source == "local", variant.trustStatus == "local-unverified",
              !variant.official, !variant.recipeValidated,
              variant.androidSignature?.verified == true,
              (variant.missingRequiredFiles ?? []).isEmpty else {
            throw LocalAPKVariantError.invalidRecord("Receita experimental e APK local não atendem à identidade, integridade, assinatura ou perfil 850 exigidos.")
        }
        try LocalAPKVariantStore.requireCompatibleDependencies(variant, recipe: recipe)
        guard let directory = RecipeValidation176.obbDirectory(target: metadata.target, package: metadata.package,
                engine: metadata.engine, version: 850) else {
            throw LocalAPKVariantError.invalidRecord("Layout externo da engine desconhecido.")
        }
        let obbNames: Set<String> = ["main.\(metadata.versionCode).\(metadata.package).obb",
                                     "patch.\(metadata.versionCode).\(metadata.package).obb"]
        var destinations = Set<String>()
        var sources = Set<String>()
        for asset in variant.assets ?? [] {
            let source = URL(fileURLWithPath: asset.sourcePath)
            let file = try asset.additionalRecipeFile()
            guard asset.sourcePath.hasPrefix("/"), source.standardizedFileURL.path == asset.sourcePath,
                  asset.size > 0, asset.sha256.count == 64, asset.sha256.allSatisfy(\.isHexDigit),
                  asset.recipeSizeMatches, asset.recipeHashMatches != false,
                  Recipe.isSafeName(source.lastPathComponent),
                  file.localName == source.lastPathComponent,
                  sources.insert(asset.sourcePath).inserted,
                  let destination = asset.destination, destination.hasPrefix("android-files/"),
                  Recipe.isSafeRelativePath(destination), destinations.insert(destination.lowercased()).inserted else {
                throw LocalAPKVariantError.invalidRecord("Arquivo externo experimental sem identidade ou destino único e seguro: \(asset.name)")
            }
            // An OBB cannot be relabelled as an arbitrary asset to evade package/version checks.
            if source.pathExtension.lowercased() == "obb" {
                guard obbNames.contains(source.lastPathComponent), file.dest == directory else {
                    throw LocalAPKVariantError.invalidRecord("OBB diverge do package, versão ou layout da engine: \(source.lastPathComponent)")
                }
            }
        }
        // Older recipes may pin associated files in their metadata; newer imports pin them
        // in the variant. Neither representation may silently omit a previously pinned input.
        for external in metadata.associatedFiles {
            guard external.isSafeForExperimentalRecipe,
                  external.package == metadata.package, external.versionCode == String(metadata.versionCode),
                  let asset = variant.assets?.first(where: { $0.sourcePath == external.path }),
                  asset.size == external.size, asset.sha256.lowercased() == external.sha256?.lowercased(),
                  asset.destination == external.destination.map({ $0 + "/" + external.fileName }) else {
                throw LocalAPKVariantError.invalidRecord("Arquivo fixado na receita experimental ausente ou divergente da variante.")
            }
        }
    }

    public static func requireValidated(recipe: Recipe, selected: ValidatedLocalAPKVariant) throws {
        guard let metadata = recipe.localExperimental else { return }
        try requireEligible(recipe: recipe, variant: selected.variant)
        guard selected.inspection.splitName == nil,
              selected.inspection.nativeLibraries.sorted() == metadata.nativeLibraries.sorted() else {
            throw LocalAPKVariantError.invalidRecord("APK split ou bibliotecas nativas divergem da receita revisada.")
        }
        try RecipeValidation176.validate(selected.inspection, recipe: recipe, version: 850)
        let associatedNames = Set((selected.variant.assets ?? []).map {
            URL(fileURLWithPath: $0.sourcePath).lastPathComponent.lowercased()
        })
        let missing = Klepton850RecipeRules.obbNames(in: selected.inspection.externalFileReferences)
            .filter { !associatedNames.contains($0.lowercased()) }
        guard missing.isEmpty else {
            throw LocalAPKVariantError.invalidRecord("OBB referenciado pelo manifesto não associado: " + missing.joined(separator: ", "))
        }
        let signature = try AndroidAPKSignature.inspect(selected.apk)
        guard signature.verified else {
            throw LocalAPKVariantError.invalidRecord("Assinatura Android atual não verificada: \(signature.detail)")
        }
        // Inspect bytes, not just the lib/arm64-v8a directory name. No guest code runs.
        _ = try ApkUnpacker.run(["/usr/bin/python3", "-c", Self.abiScript, selected.apk.path,
                                 "lib/arm64-v8a/\(metadata.entrypoint).so"])
    }

    private static let abiScript = #"""
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    entry = sys.argv[2]
    for name in z.namelist():
        if not name.startswith('lib/arm64-v8a/') or not name.endswith('.so'): continue
        with z.open(name) as f: header = f.read(64)
        if header[:4] != b'\x7fELF':
            # Match the pinned Makefile's ELF discovery: .so may also name data.
            # Data is not translated, but the actual entrypoint must be executable code.
            if name == entry: raise ValueError('Native entrypoint is not ELF: ' + name)
            continue
        if len(header) != 64 or header[4:6] != b'\x02\x01' or int.from_bytes(header[18:20], 'little') != 183:
            raise ValueError('Native library is not ELF64 AArch64 little-endian: ' + name)
    if entry not in z.namelist(): raise ValueError('Missing native entrypoint: ' + entry)
"""#

    public static func requireLocalStep(_ step: InstallStep, variantID: String?) throws {
        guard variantID != nil, step != .unlock else {
            throw RecipeError.invalid("Receita experimental exige variante local; downloads e desbloqueio Meta não fazem parte deste fluxo.")
        }
    }

    /// Only live Jobs are candidates. Never recreate a deleted Job from a receipt or backup,
    /// and never mutate a build merely to make it reusable.
    public static func existingBuild(jobs: JobStore, workspaceRoot: URL, recipe: Recipe,
        variant: LocalAPKVariant, toolchain: Toolchain, requested: InstallRequest,
        report: @escaping @Sendable (String) -> Void = { _ in }) throws -> (ReusableBuild, Job)? {
        try RuntimePolicy177.requireSource(toolchain)
        let assetsHash = try LocalAPKBuildEvidence.assetsHash(variant)
        for job in jobs.all().sorted(by: { $0.created > $1.created }) where job.state == .finished
            && job.steps == [.buildOnly] && job.recipe.id == recipe.id
            && job.request.localAPKVariantID == variant.id
            && job.request.localAssetsSHA256 == assetsHash
            && LocalBuildRecovery.runtimeCompatible(job.request, with: requested)
            && (requested.roomMeasuring == nil || requested.roomMeasuring == job.request.roomMeasuring)
            && (requested.gameLanguage == nil || requested.gameLanguage == job.request.gameLanguage)
            && (requested.displayName == nil || requested.displayName == job.request.displayName)
            && (requested.displaySuffix == nil || requested.displaySuffix == job.request.displaySuffix)
            && (requested.customIcon == nil || requested.customIcon == job.request.customIcon) {
            do {
                let bundle = job.request.bundleId ?? Toolchain.defaultBundleId(target: recipe.toolchain.target)
                if let artifact = try ReusableBuild.find(jobs: jobs, workspaceRoot: workspaceRoot,
                    recipe: recipe, request: job.request, bundleID: bundle, apkHash: variant.sha256,
                    toolchain: toolchain, report: report, snapshots: [job]) {
                    return (artifact, job)
                }
            } catch {
                report("[Reuso] Job \(job.id) rejeitado e preservado: \(error)")
            }
        }
        report("[Reuso] Nenhum Build Only atual íntegro e compatível; a instalação precisará de um workspace novo. Jobs e builds anteriores preservados.")
        return nil
    }
}
