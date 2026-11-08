import AVPPlayCore
import SwiftUI

/// Testimony about one installation, displayed with its exact identity rather than a game-wide badge.
struct FunctionalityReceiptView: View {
    @EnvironmentObject var model: AppModel
    let receipt: LocalAPKInstallation
    let variant: LocalAPKVariant
    let recipe: Recipe
    var historical: Bool = false
    var showTechnicalDetails: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if historical { Text("Histórico desta instalação — não representa outro build ou a instalação atual.").font(.caption).foregroundStyle(.secondary) }
            if receipt.legacyRecovery != nil {
                Text("Instalação anterior: artefatos locais e histórico verificados, sem reinstalação.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Instalação de \(receipt.date.formatted())")
                .font(.caption).textSelection(.enabled)
            if receipt.functionalityStatus != nil {
                Label("Funcionamento confirmado no Vision Pro", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green).font(.callout.bold())
                if model.localLearning(recipe)?.current?.hashes[variant.sha256] != variant.size {
                    Button("Salvar hash na receita local") { model.saveConfirmedHashLater(receipt, variant: variant, recipe: recipe) }
                        .disabled(model.verifyingLegacyFunctionality.contains(receipt.id))
                }
                if let date = receipt.confirmedAt { Text("Confirmado por você em \(date.formatted())").font(.caption) }
                HStack {
                    Button("Instalar com configuração confirmada…") {
                        model.reuseFunctionality(receipt, variant: variant, recipe: recipe)
                    }.disabled(model.isBusy(recipe.id))
                }
            } else if receipt.build != nil, receipt.configuration != nil, !historical {
                if let date = receipt.revokedAt { Text("Confirmação revogada em \(date.formatted())").font(.caption).foregroundStyle(.secondary) }
                Text("Este build ainda não tem confirmação de funcionamento.").font(.caption).foregroundStyle(.secondary)
                Button("Testado e funcionando") {
                    model.confirmFunctionalityWithHashChoice(receipt, variant: variant, recipe: recipe)
                }.disabled(model.verifyingLegacyFunctionality.contains(receipt.id))
                if model.verifyingLegacyFunctionality.contains(receipt.id) {
                    ProgressView("Revalidando os artefatos antes de registrar sua confirmação…").controlSize(.small)
                }
                Text("Clique após testar esta instalação no Vision Pro. É um relato pessoal; não comprova autenticidade, licença ou compatibilidade universal.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if showTechnicalDetails {
                DisclosureGroup("Configurações avançadas") {
                    FunctionalityReceiptDetailsView(receipt: receipt, variant: variant, recipe: recipe)
                }
            }
        }
    }
}

struct FunctionalityReceiptDetailsView: View {
    @EnvironmentObject var model: AppModel
    let receipt: LocalAPKInstallation
    let variant: LocalAPKVariant
    let recipe: Recipe
    var body: some View {
                VStack(alignment: .leading, spacing: 4) {
                    if receipt.functionalityStatus != nil {
                        Button("Corrigir relato de funcionamento…") {
                            model.setFunctionality(receipt, variant: variant, recipe: recipe, confirmed: false)
                        }.help("Preserva o hash, a confirmação anterior e a identidade do build no histórico.")
                    }
                    Text("\(receipt.gameTitle ?? recipe.title) · receita \(receipt.recipeID ?? recipe.id)")
                    Text("\(receipt.package) · versionCode \(receipt.versionCode) · variante \(receipt.variantID)")
                    Text("APK SHA-256: \(receipt.sha256)")
                    Text("Klepton: \(receipt.toolchain) · Vision Pro: \(receipt.deviceID)")
                    if let build = receipt.build {
                        Text("Build compilado (antes da assinatura) SHA-256: \(build.unsignedBuildSHA256)")
                        Text("Produto assinado SHA-256 (inclui assinatura): \(build.signedBuildSHA256)")
                        Text("Receita SHA-256: \(build.recipeSHA256)")
                        if let hash = build.assetsSHA256 { Text("Manifesto de todos os dados importados SHA-256: \(hash)") }
                        if let hash = build.requiredFilesSHA256 { Text("Arquivos obrigatórios selecionados SHA-256: \(hash)") }
                        if let hash = build.optionalFilesSHA256 { Text("Arquivos opcionais selecionados SHA-256: \(hash)") }
                        Text("Os manifestos não substituem a verificação individual. Cada nova instalação começa não testada, mesmo usando o mesmo APK.")
                        ForEach(build.settings.keys.sorted(), id: \.self) { key in
                            Text("\(key): \(build.settings[key] ?? "")")
                        }
                    }
                }.font(.caption).textSelection(.enabled)
    }
}
