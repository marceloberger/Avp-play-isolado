import AVPPlayCore
import SwiftUI

struct LocalBundleIdentityControls: View {
    static let initiallyExpanded = false
    @EnvironmentObject private var model: AppModel
    let recipe: Recipe
    let variantID: String
    @State private var destination = ""
    @State private var source = ""
    @State private var message = ""
    @State private var expanded = initiallyExpanded

    var body: some View {
        DisclosureGroup("Preservar identidade", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Para atualizar uma instalação existente, informe os identificadores somente se a seleção automática não tiver evidências suficientes. A escolha vale para este jogo e arquivo importado.")
                TextField("Bundle ID instalado a preservar", text: $destination)
                TextField("Bundle ID do Build only existente", text: $source)
                HStack {
                    Button("Salvar identidade explícita") {
                        do {
                            try model.saveLocalBundleIdentity(LocalBundleIdentity(destination: destination, source: source), recipe: recipe, variantID: variantID)
                            message = "Identidade salva. A próxima instalação reutilizará uma cópia do Build only. Nenhuma operação foi iniciada."
                        } catch { message = String(describing: error) }
                    }
                    Button("Usar identidade padrão") {
                        do {
                            try model.saveLocalBundleIdentity(nil, recipe: recipe, variantID: variantID)
                            destination = ""; source = ""; message = "Seleção explícita removida."
                        } catch { message = String(describing: error) }
                    }
                }
                Text("O original é preservado. Perfil, certificado, dispositivo e permissões continuam sendo verificados. Mesmo Team ID não comprova compatibilidade com a assinatura instalada; confirme App ID Prefix e acesso ao Keychain antes de atualizar.")
                    .font(.caption).foregroundStyle(.secondary)
                if !message.isEmpty { Text(message).font(.callout) }
            }.padding(.top, 8).textFieldStyle(.roundedBorder)
        }.onAppear {
            if let choice = try? model.localBundleIdentity(recipeID: recipe.id, variantID: variantID) {
                destination = choice.destination; source = choice.source
            }
        }
    }
}
