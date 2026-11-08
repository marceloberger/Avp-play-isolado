import AVPPlayCore

/// Rendering performs no device, profile or credential queries. Installer repeats the full
/// technical validation and Apple signing preflight before any external operation.
enum LocalInstallReadiness {
    static func canStart(recipe: Recipe, variant: LocalAPKVariant, runtimeAvailable: Bool,
                         xcodeAvailable: Bool, teamValid: Bool, deviceAvailable: Bool) -> Bool {
        guard runtimeAvailable, xcodeAvailable, teamValid, deviceAvailable,
              variant.versionMatchesRecipe == true, variant.androidSignature?.verified == true,
              (variant.missingRequiredFiles ?? []).isEmpty else { return false }
        return (try? LocalAPKVariantStore.requireCompatibleDependencies(variant, recipe: recipe)) != nil
            && (try? LocalExperimentalAdmission.requireEligible(recipe: recipe, variant: variant)) != nil
    }
}
