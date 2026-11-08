import Foundation

/// Shared by import review and the actual Prepare path (also called by Build Only).
/// Selection remains with the caller; validation never chooses a different runtime.
public enum RecipeValidation176 {
    public static func obbDirectory(target: String?, package: String, engine: LocalGenericEngine?, version: Int) -> String? {
        guard Recipe.isSafeName(package), [824, 850].contains(version) else { return nil }
        let override = version == 850
            ? Klepton850RecipeRules.obbOverride(target: target, package: package)
            : Klepton824RecipeRules.obbOverride(target: target, package: package)
        if let override { return override }
        switch engine {
        case .unreal4, .unreal, .nativeActivity: return "android-files/Android/obb/" + package
        case .unity, .sdl2: return "android-files/obb"
        default: return nil
        }
    }

    public static func identityBlockers(_ apk: ApkUnpacker.Inspection, identity: AutomaticAPKIdentity?) -> [String] {
        guard let identity else { return [] }
        let analysis = LocalGenericTargetAnalysis.inspect(apk)
        var errors: [String] = []
        if identity.package != apk.package { errors.append("Package diverge da identidade do APK") }
        if let expected = identity.targetEngine,
           analysis.engine.map(Klepton850RecipeRules.engineName) != expected {
            errors.append("Engine observada diverge de targetEngine: " + expected)
        }
        if let expected = identity.targetEntrypoint, analysis.entrypoint != expected {
            errors.append("Entrypoint diverge do target publicado")
        }
        if let expected = identity.targetVersionCode, apk.versionCode != expected {
            errors.append("VersionCode diverge do target publicado")
        }
        return errors
    }

    public static func validate(_ apk: ApkUnpacker.Inspection, recipe: Recipe, version: Int) throws {
        guard [824, 850].contains(version) else { throw RecipeError.invalid("Runtime sem regras 824/850") }
        let analysis = LocalGenericTargetAnalysis.inspect(apk)
        var errors = identityBlockers(apk, identity: AutomaticAPKIdentity.resolve(package: recipe.package))
        if let metadata = recipe.localExperimental {
            errors += analysis.blockers
            let expected = version == 850 ? ExperimentalRuntime183.klepton850 : .klepton824
            if metadata.toolchain != expected.rawValue || recipe.toolchain.minCommit != expected.minCommit {
                errors.append("Runtime selecionado diverge do perfil da receita experimental; revise explicitamente a receita")
            }
            if analysis.engine != metadata.engine || analysis.entrypoint != metadata.entrypoint {
                errors.append("Engine ou entrypoint diverge da receita experimental revisada")
            }
            if apk.package != recipe.package || apk.versionCode != String(recipe.versionCode) {
                errors.append("Identidade do APK diverge da receita")
            }
        }
        guard errors.isEmpty else { throw RecipeError.invalid(errors.joined(separator: "; ")) }
    }
}
