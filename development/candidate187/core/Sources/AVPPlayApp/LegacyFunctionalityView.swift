import AVPPlayCore
import SwiftUI

struct LegacyFunctionalityView: View {
    @EnvironmentObject var model: AppModel
    let receipt: LocalAPKInstallation
    let variant: LocalAPKVariant
    let recipe: Recipe
    var showTechnicalDetails: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let problem = model.legacyFunctionalityProblems[receipt.id] {
                Label("Não foi possível recuperar esta instalação anterior", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                if showTechnicalDetails { Text(problem).font(.caption).textSelection(.enabled) }
                Text("Preserve os artefatos e recupere o arquivo indicado. Não é necessário iniciar uma instalação para verificar novamente.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Verificar novamente") { model.inspectLegacyFunctionality(receipt, variant: variant, recipe: recipe, retry: true) }
                    .disabled(model.verifyingLegacyFunctionality.contains(receipt.id))
            } else if let recovered = model.legacyFunctionalityCandidates[receipt.id] {
                FunctionalityReceiptView(receipt: recovered, variant: variant, recipe: recipe, showTechnicalDetails: showTechnicalDetails)
            } else {
                ProgressView("Verificando APK, Jobs e artefatos da instalação anterior…").controlSize(.small)
                Text("Somente leitura local. O funcionamento só será confirmado pelo seu clique.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: receipt.id) { model.inspectLegacyFunctionality(receipt, variant: variant, recipe: recipe) }
    }
}
