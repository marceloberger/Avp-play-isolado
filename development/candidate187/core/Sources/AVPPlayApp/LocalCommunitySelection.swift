import AVPPlayCore
import Foundation

struct LocalCommunitySelectionChoice: Identifiable, Equatable, Sendable {
    let recipeID: String
    let variantID: String
    let title: String
    let version: String
    let sha256: String
    var id: String { recipeID + ":" + variantID }
}

enum LocalCommunitySelectionResolution: Equatable {
    case unchanged
    case restored(LocalCommunitySelectionChoice)
    case verifyAgain(String)
    case choose([LocalCommunitySelectionChoice], String)
}

/// Restores a community recipe only from an exact, uniquely validated local APK variant.
/// The provisional record remains stored and visible for inspection.
enum LocalCommunitySelectionRestoration {
    static func resolve(savedRecipeID: String, explicitlySelected: Bool,
                        provisionalRecords: [LocalProvisionalRecipe], recipes: [Recipe],
                        variants: LocalAPKVariantStore) -> LocalCommunitySelectionResolution {
        guard !explicitlySelected,
              let record = provisionalRecords.first(where: { $0.id == savedRecipeID }),
              let derived = record.experimentalRecipe ?? record.communityRecipe else { return .unchanged }

        let recipeCandidates = recipes.filter { recipe in
            guard recipe.id == derived.id, recipe.package == record.package,
                  recipe.versionCode == Int(record.versionCode ?? ""),
                  recipe.versionName == (record.versionName ?? ""),
                  recipe.toolchain.target == derived.toolchain.target,
                  let apk = recipe.files.first(where: { $0.role == "apk" }) else { return false }
            return (apk.id == "local-community" || apk.id == "local-experimental")
                && apk.name == URL(fileURLWithPath: record.apkPath).lastPathComponent
                && apk.localName == "\(derived.toolchain.target).apk"
        }
        guard !recipeCandidates.isEmpty else { return .unchanged }

        var exact: [LocalCommunitySelectionChoice] = []
        var sameVersion: [LocalCommunitySelectionChoice] = []
        var reusable: [LocalCommunitySelectionChoice] = []
        for recipe in recipeCandidates {
            for variant in variants.variants(for: recipe) where variant.source == "local"
                && !variant.official && !variant.recipeValidated
                && variant.recipeID == recipe.id && variant.recipeVersionCode == recipe.versionCode
                && variant.package == record.package && variant.versionCode == record.versionCode
                && variant.versionName == record.versionName {
                let choice = LocalCommunitySelectionChoice(recipeID: recipe.id, variantID: variant.id,
                    title: recipe.title, version: "\(variant.versionName ?? "") (\(variant.versionCode))",
                    sha256: variant.sha256)
                sameVersion.append(choice)
                guard variant.sha256.lowercased() == record.apkSHA256.lowercased(),
                      variant.size == record.apkSize else { continue }
                exact.append(choice)
                if variants.hasReusablePreparationValidation(id: variant.id, for: recipe, expected: variant),
                   variant.versionMatchesRecipe == true, variant.androidSignature?.verified == true,
                   (variant.missingRequiredFiles ?? []).isEmpty,
                   (try? LocalAPKVariantStore.requireCompatibleDependencies(variant, recipe: recipe)) != nil {
                    reusable.append(choice)
                }
            }
        }

        if exact.count == 1, reusable.count == 1 { return .restored(reusable[0]) }
        if reusable.count > 1 { return .choose(reusable, "Há mais de uma variante comunitária validada para este registro. Escolha explicitamente a variante a abrir.") }
        if exact.count == 1 { return .verifyAgain("A variante corresponde ao APK, mas o recibo de validação não corresponde mais à identidade atual dos arquivos. Verifique novamente antes de continuar.") }
        if exact.count > 1 { return .choose(exact, "Há variantes duplicadas com a mesma identidade de APK. Escolha explicitamente uma variante.") }
        if sameVersion.count > 1 { return .choose(sameVersion, "Há várias variantes desta versão. Escolha explicitamente qual APK usar.") }
        if sameVersion.count == 1 { return .choose(sameVersion, "A variante registrada não corresponde ao hash do APK provisório. Escolha explicitamente ou mantenha o cartão provisório.") }
        return .unchanged
    }
}
