import AVPPlayCore
import SwiftUI

struct LocalPrognosisView170: View {
    @EnvironmentObject var model: AppModel
    let recipe: Recipe
    let variant: LocalAPKVariant
    @State private var result: Prognosis?
    @State private var fingerprint: Fingerprint?
    @State private var busy = false
    @State private var note = "Desconhecido — calcule com o APK, referências verificadas e runtime disponíveis."
    private var identity: String { variant.id + ":" + variant.sha256 + ":" + (model.toolchain?.commit() ?? "unknown") }
    var body: some View {
        GroupBox("Prognóstico de compatibilidade") {
            VStack(alignment: .leading, spacing: 8) {
                Text(result?.summary ?? note).font(.callout)
                Text("Estimativa estática; não comprova execução. Não detecta anti-cheat ou exigências de servidores.").font(.caption).foregroundStyle(.secondary)
                if let result {
                    ForEach(result.neighbours, id: \.id) { n in
                        Text("Comparável: \(n.title) · \(Int((n.similarity * 100).rounded()))%").font(.caption)
                    }
                }
                Button(busy ? "Analisando…" : "Calcular prognóstico local") { calculate() }.disabled(busy)
                if let fingerprint {
                    Button("Compartilhar este fingerprint com o projeto") {
                        model.shareFingerprint(fingerprint, of: recipe)
                    }.disabled(!FingerprintConsent170.allows(enabled: model.shareFingerprints, explicitAction: true,
                                                             online: model.onlineCatalog,
                                                             game: UsagePing.gameKey(appId: recipe.catalogAppId, recipe: recipe.id)))
                }
                Text("Nenhum envio durante importação ou cálculo. Compartilhar exige ativação em Configurações e clique no botão.").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .id(identity)
        .onChange(of: identity) { _, _ in result = nil; fingerprint = nil; note = "Desconhecido — dados ou runtime mudaram." }
    }
    private func calculate() {
        busy = true; result = nil; fingerprint = nil
        let registry = model.localVariantStore, runtime = model.toolchain, recipes = model.paths.recipes
        let captured = identity
        Task {
            let data = await Task.detached(priority: .utility) { () -> (Fingerprint?, Prognosis?) in
                guard let selected = try? registry.validated(id: variant.id, for: recipe, verifyAssetHashes: false),
                      let fp = try? Fingerprint.make(apk: selected.apk) else { return (nil, nil) }
                let interface = runtime.flatMap { try? RuntimeInterface.scan(klepton: $0.root) }
                let refs = recipes.map { ReferenceFingerprint.bundled(recipes: $0) } ?? []
                return (fp, LocalPrognosis170.assess(fp, runtime: interface, references: refs))
            }.value
            busy = false
            guard captured == identity else { return }
            fingerprint = data.0; result = data.1
            note = "Desconhecido — faltam dados confiáveis do APK, runtime ou jogos de referência."
        }
    }
}

struct ProvisionalPrognosisView170: View {
    @EnvironmentObject var model: AppModel
    let record: LocalProvisionalRecipe
    @State private var result: Prognosis?
    @State private var busy = false
    var body: some View {
        GroupBox("Prognóstico de compatibilidade") {
            VStack(alignment: .leading, spacing: 6) {
                Text(result?.summary ?? "Desconhecido — ainda não há evidências suficientes analisadas.")
                Button(busy ? "Analisando…" : "Calcular prognóstico local") { calculate() }.disabled(busy)
                Text("Estimativa estática, sem confirmação de execução ou envio de dados.").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func calculate() {
        busy = true; result = nil
        let runtime = model.toolchain, recipes = model.paths.recipes
        Task {
            let answer = await Task.detached(priority: .utility) { () -> Prognosis? in
                let apk = URL(fileURLWithPath: record.apkPath)
                guard (try? Hashing.sha256(of: apk)) == record.apkSHA256,
                      let fp = try? Fingerprint.make(apk: apk) else { return nil }
                return LocalPrognosis170.assess(fp, runtime: runtime.flatMap { try? RuntimeInterface.scan(klepton: $0.root) },
                    references: recipes.map { ReferenceFingerprint.bundled(recipes: $0) } ?? [])
            }.value
            result = answer; busy = false
        }
    }
}
