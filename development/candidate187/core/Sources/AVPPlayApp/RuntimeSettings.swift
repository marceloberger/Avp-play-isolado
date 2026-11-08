import AVPPlayCore
import SwiftUI

struct OptionalRuntimeSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var busy = false
    @State private var message: String?
    var body: some View {
        Section("Preferências gerais para novas compilações") {
            Text("Novas compilações usam exclusivamente o Klepton 850 cc2856c + TLS168. Jobs antigos são preservados; operações com 824 são bloqueadas.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Suporte global a Surreal Touch", isOn: $model.surrealSupport)
            Picker("Modo inicial dos controles", selection: $model.controllerMode) {
                ForEach(ControllerMode.allCases) { Text($0.title).tag($0) }
            }
            Text("Standard Controllers é o padrão. O runtime inclui suporte padrão a PSVR2 Sense; o funcionamento depende do jogo e não está confirmado para todos os títulos.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Frame Generation", selection: $model.defaultFrameGeneration) {
                ForEach(FrameGeneration.allCases, id: \.rawValue) { Text($0.title).tag($0) }
            }
            Text("Automático / padrão do Klepton é o padrão. Off, Ahead e In between são escolhas explícitas. Sem override por jogo, estas preferências são copiadas para cada novo Job.")
                .font(.caption).foregroundStyle(.secondary)
            Text("SDK Surreal global: verificado. O fallback Bluetooth fica nas opções avançadas de cada jogo.")
                .font(.caption).foregroundStyle(.secondary)
            Text("A precedência é: override avançado do jogo, depois preferência geral. A mudança afeta somente Jobs criados depois dela; não edita Jobs salvos nem configurações de jogos instalados.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Verificar integridade Klepton 850 + TLS168") {
                busy = true
                let root = model.paths.packager.root.appendingPathComponent("850-cc2856c")
                Task {
                    message = await Task.detached { () -> String in
                        do { try RuntimePolicy177.requireSource(Toolchain(root: root)); return RuntimePolicy177.label + ": íntegro." }
                        catch { return RuntimePolicy177.blocked + " " + String(describing: error) }
                    }.value
                    busy = false
                }
            }.disabled(busy)
            if busy { ProgressView() }
            if let message { Text(message).font(.caption).textSelection(.enabled) }
        }
    }
}

struct RuntimeGameSettings: View {
    @EnvironmentObject var model: AppModel
    let recipe: Recipe
    private var game: Game { model.localGame(for: recipe) }
    private var runtime: Toolchain? { model.toolchain(for: game) }
    private var resolvedTarget: String { KleptonRecipeCompatibility.resolve(recipe).toolchain.target }
    private func binding<T>(_ get: @escaping (GameOptions) -> T, _ set: @escaping (inout GameOptions,T) -> Void) -> Binding<T> {
        Binding(get: { get(model.options(for: game)) }, set: { value in
            var options = model.options(for: game); set(&options,value); model.setOptions(options,for: game)
        })
    }
    var body: some View {
        GroupBox("Runtime da próxima construção") {
            VStack(alignment: .leading, spacing: 10) {
                if let folder = model.paths.recipes,
                   let primary = try? RecipeStore(directory: folder).load(id: recipe.id) {
                    let variants = [primary] + RecipeStore(directory: folder).loadVariants().filter { $0.id == recipe.id && $0.source == primary.source }
                    if variants.count > 1 {
                        Picker("Versão local", selection: Binding(get: { recipe.versionCode }, set: { code in
                            guard !model.isBusy(recipe.id), variants.contains(where: { $0.versionCode == code }) else { return }
                            var choices = StoreUpdate.Choices.load()
                            choices.choose(code == primary.versionCode ? nil : code, for: recipe.id)
                            do { try choices.save(); model.latestChoices = choices; model.loadLocalRecipes() }
                            catch { model.notice = "Não foi possível escolher a versão: \(error)" }
                        })) {
                            ForEach(variants,id: \.versionCode) { item in Text(item.versionName).tag(item.versionCode) }
                        }
                    }
                }
                GroupBox("Klepton 850 + TLS168 — próxima compilação") {
                    if let runtime {
                        if runtime.hasTarget(resolvedTarget) {
                            Label("Klepton \(runtime.version()) (\(runtime.commit())) verificado; target específico \(resolvedTarget).",
                                  systemImage: "checkmark.seal")
                                .font(.callout).textSelection(.enabled)
                        } else {
                            Label("Klepton \(runtime.version()) (\(runtime.commit())) verificado; target genérico experimental \(resolvedTarget). A engine será inferida do APK; ajustes específicos do jogo ainda podem ser necessários.",
                                  systemImage: "flask")
                                .font(.callout).textSelection(.enabled).foregroundStyle(.secondary)
                        }
                    } else {
                        Label("Klepton 850 + TLS168 verificado ausente, commit mínimo não satisfeito ou target inválido. Nenhuma compilação pode prosseguir; a 750 não será usada como fallback.", systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange)
                    }
                    Text("Targets genéricos são tentativas experimentais e não comprovam execução. Jobs já salvos conservam sua configuração original.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup("Opções avançadas desta compilação") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Suporte Surreal Touch", selection: binding({ $0.surrealSupport }, { $0.surrealSupport = $1 })) {
                            Text("Usar preferência geral (\(model.surrealSupport ? "Ativado" : "Desativado"))").tag(nil as Bool?)
                            Text("Ativado para este jogo").tag(Optional(true))
                            Text("Desativado para este jogo").tag(Optional(false))
                        }.disabled(runtime?.supportsRuntime824 != true)
                        Picker("Modo inicial dos controles", selection: binding({ $0.controllerMode }, { $0.controllerMode = $1 })) {
                            Text("Usar preferência geral (\(model.controllerMode.title))").tag(nil as ControllerMode?)
                            ForEach(ControllerMode.allCases) { Text($0.title).tag(Optional($0)) }
                        }.disabled(runtime?.supportsRuntime824 != true)
                        Picker("Frame Generation", selection: binding({ $0.frameGeneration }, { $0.frameGeneration = $1 })) {
                            Text("Usar preferência geral (\(model.defaultFrameGeneration.title))").tag(nil as FrameGeneration?)
                            ForEach(FrameGeneration.allCases, id: \.rawValue) { Text($0.title).tag(Optional($0)) }
                        }.disabled(runtime?.supportsRuntime824 != true)
                        Picker("SDK Surreal", selection: binding({ $0.surrealSDK }, { $0.surrealSDK = $1 })) {
                            Text("Usar padrão geral (SDK verificado)").tag(nil as SurrealSDKPolicy?)
                            Text("SDK verificado — rastreamento e alinhamento").tag(Optional(SurrealSDKPolicy.verified))
                            Text("Fallback Bluetooth explícito").tag(Optional(SurrealSDKPolicy.bluetooth))
                        }.disabled(runtime?.supportsRuntime824 != true || !(model.options(for: game).surrealSupport ?? model.surrealSupport))
                    }
                    Text("Overrides são salvos por jogo e vencem a preferência geral ao criar um Job. Jobs já criados e builds existentes não são alterados.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if recipe.toolchain.target == "beatsaber140" {
                    Toggle("Mods e busca de músicas (somente 1.45.3 / 824)",
                           isOn: binding({ $0.coreMods == true }, { $0.coreMods = $1 }))
                        .disabled(runtime?.coreModsProfile(for: recipe) == nil)
                    Text("SongCore, BSML, BetterSongSearch, SongDownloader e PlaylistCore. Apple Music Search solicita acesso no headset; a busca de mapas consulta BeatSaver. Desligado por padrão. As versões anteriores permanecem disponíveis.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Estas escolhas só entram numa construção solicitada por você. Saves e preferências já escolhidas no jogo são preservados. Jogos existentes precisam de reconstrução autorizada para receber o runtime novo.")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity,alignment: .leading)
        }
    }
}
