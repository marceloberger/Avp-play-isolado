import AVPPlayCore
import SwiftUI

/// Beat Saber search runs inside the game mod. This Mac page exposes the existing per-game option
/// and links directly to the game's detail page; it does not control Apple Music playback on macOS.
struct AppleMusicSearchView: View {
    @EnvironmentObject private var model: AppModel

    private var game: Game? {
        let candidates = model.allGames.filter { $0.recipe.toolchain.target == "beatsaber140" }
        return candidates.first(where: { model.toolchain(for: $0)?.coreModsProfile(for: $0.recipe) != nil })
            ?? candidates.first
            ?? model.localRecipes.first(where: { $0.toolchain.target == "beatsaber140" }).map(model.localGame(for:))
    }

    private var supportsSearch: Bool {
        guard let game else { return false }
        return model.toolchain(for: game)?.coreModsProfile(for: game.recipe) != nil
    }

    private var modsEnabled: Bool { game.map { model.options(for: $0).coreMods == true } ?? false }

    var body: some View {
        Form {
            Section("Apple Music Search no Beat Saber") {
                Text("Apple Music Search é um recurso do mod de Beat Saber executado no Vision Pro. Esta página controla a opção do próximo build; ela não é um player de música do Mac.")
                    .font(.callout).foregroundStyle(.secondary)
                if let game {
                    LabeledContent("Jogo", value: "\(game.recipe.title) · \(game.recipe.versionName)")
                    Toggle("Mods de Beat Saber, incluindo Apple Music Search", isOn: Binding(
                        get: { model.options(for: game).coreMods == true },
                        set: { model.setAppleMusicSearchEnabled($0, for: game) }))
                        .disabled(!supportsSearch || model.isBusy(game.id))
                    Text(supportsSearch
                         ? "A opção é salva para este jogo e aplicada somente quando um novo build for solicitado. Ela não modifica Jobs nem builds existentes."
                         : "O runtime Klepton 824 verificado e a receita Beat Saber 1.45.3 com perfil de mods são necessários. A opção ficará disponível quando ambos forem reconhecidos.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Abrir Beat Saber em Games") {
                        model.openAppleMusicSearchOptions(for: game)
                    }
                    .accessibilityIdentifier("appleMusic.openBeatSaber")
                } else {
                    ContentUnavailableView("Receita Beat Saber indisponível", systemImage: "music.note",
                                           description: Text("Carregue a biblioteca de jogos para ver a versão e o perfil compatíveis. Nenhuma consulta ou build é iniciado por esta página."))
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Apple Music Search")
        .accessibilityIdentifier("navigation.appleMusic")
    }
}

/// AVP Play Remote's isolated controls are now a first-class navigation destination, matching the
/// original app's Remote Control page while keeping the isolated client identity and safeguards.
struct RemoteControlPage: View {
    var body: some View {
        NavigationStack {
            Form {
                IsolatedRemoteSettings()
                IsolatedRemoteBuildSettings()
            }
            .formStyle(.grouped)
            .navigationTitle("Remote Control")
            .navigationDestination(for: String.self) { route in
                if IsolatedRemoteNavigation.destination(for: route) == .companionDetail {
                    IsolatedRemoteCompanionDetail()
                }
            }
        }
        .accessibilityIdentifier("navigation.remote")
    }
}
