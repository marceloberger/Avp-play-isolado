import AppKit
import AVPPlayCore
import SwiftUI

/// Restored library discovery. Existing recipe downloads continue through fetchFromSteam.
extension AppModel {
    func resetSteamLibrary() {
        steamLibraryGeneration = UUID()
        steamLibraryAccount = nil
        steamLibrary = nil
        loadingSteamLibrary = false
        steamLibraryProblem = nil
    }

    func loadSteamLibrary(force: Bool = false) {
        guard steamSignedIn, storeBlocker == nil else { return }
        let account = steamAccount
        if steamLibraryAccount != account { resetSteamLibrary(); steamLibraryAccount = account }
        guard !loadingSteamLibrary else { return }
        let cache = SteamLibraryCache(store: paths.store, account: account)
        if steamLibrary == nil { steamLibrary = cache.load() }
        if !force, let steamLibrary, !steamLibrary.isStale() { return }
        loadingSteamLibrary = true
        let token = UUID(); steamLibraryGeneration = token
        Task {
            let result = await Task.detached { () -> Result<SteamLibrary, Error> in
                Result { SteamLibrary(checked: Date(), apps: try SteamLibraryScan(account: account).run()) }
            }.value
            guard steamLibraryGeneration == token, steamAccount == account else { return }
            loadingSteamLibrary = false
            switch result {
            case .success(let library):
                do { try cache.save(library); steamLibrary = library; steamLibraryProblem = nil }
                catch { steamLibraryProblem = Redaction.redact(String(describing: error)) }
            case .failure(let error): steamLibraryProblem = Redaction.redact(String(describing: error))
            }
        }
    }

    func steamPlaceholders(known games: [Game]) -> [SteamAndroidApp] {
        guard steamLibraryAccount == steamAccount else { return [] }
        var known = Set(games.compactMap { $0.recipe.store.steamAppId }.map { "steam:" + $0 })
        for game in games where game.sources.contains(.steam) {
            if let id = recipe(of: game, source: .steam)?.store.steamAppId { known.insert("steam:" + id) }
        }
        return (steamLibrary?.apps ?? []).filter { known.insert("steam:" + $0.appId).inserted }
    }

    func steamDraftApp(_ game: Game) -> SteamAndroidApp? {
        guard steamLibraryAccount == steamAccount, game.draft, !game.prepared,
              game.recipe.source == .steam, let id = game.recipe.store.steamAppId else { return nil }
        return steamLibrary?.apps.first { $0.appId == id && !$0.depots.isEmpty }
    }

    func prepareFromSteam(_ game: Game) {
        guard let app = steamDraftApp(game), steamBlocker(for: game) == nil, !preparing.contains(game.id) else { return }
        let account = steamAccount, store = paths.store, token = steamLibraryGeneration
        preparing.insert(game.id)
        prepareNote[game.id] = "Consultando a licença Steam e preparando a receita…"
        steamStops.clear(game.id)
        let stops = steamStops
        Task {
            let result = await Task.detached { () -> Result<Recipe, Error> in
                Result {
                    try SteamDraftMaker(store: store, account: account).prepare(app: app,
                        target: DraftRecipe.genericTarget(appId:), minCommit: ExperimentalRuntime183.klepton850.minCommit,
                        shouldStop: { stops.isRequested(game.id) })
                }
            }.value
            preparing.remove(game.id)
            guard steamAccount == account, steamLibraryGeneration == token else { return }
            do {
                let recipe = try result.get()
                try acceptSteamRecipe(recipe, app: app)
                prepareNote[game.id] = "Receita Steam criada com SHA-256. Nenhum build ou instalação iniciado."
            } catch { prepareNote[game.id] = Redaction.redact(String(describing: error)) }
        }
    }

    /// Also exercised by UI integration tests with disposable Paths; never queues a Job.
    func acceptSteamRecipe(_ recipe: Recipe, app: SteamAndroidApp) throws {
        guard recipe.id == SteamDraft.identifier(appId: app.appId), recipe.source == .steam,
              recipe.store.steamAppId == app.appId, recipe.store.appId == nil,
              recipe.toolchain.minCommit == ExperimentalRuntime183.klepton850.minCommit else { throw SteamError.badRecipe }
        try recipe.validateForJob()
        try FileManager.default.createDirectory(at: draftsDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(recipe).write(to: draftsDirectory.appendingPathComponent(recipe.id + ".json"), options: .atomic)
        let game = Game(recipe: recipe,
            status: GameStatus.of(recipe: recipe, store: paths.store, apps: installedApps,
                toolchainVersion: toolchainRevision, bundlePrefix: customBundlePrefix.isEmpty ? nil : customBundlePrefix,
                experimental: experimentalExpected, metalFX: metalFXExpected, xrPrediction: xrPredictionExpected(for: recipe.id)),
            cover: nil, draft: true)
        if let index = games.firstIndex(where: { $0.id == recipe.id }) { games[index] = game }
        else { games.append(game) }
        rebuildAllGames()
    }
}

struct SteamDiscoveryControls: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack {
            Button(model.loadingSteamLibrary ? "Lendo biblioteca Steam…" : "Ler biblioteca Steam") { model.loadSteamLibrary(force: true) }
                .disabled(model.loadingSteamLibrary || !model.steamSignedIn)
            if model.loadingSteamLibrary { ProgressView().controlSize(.small) }
            if let problem = model.steamLibraryProblem { Text(problem).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct SteamDiscoveryLifecycle: ViewModifier {
    @EnvironmentObject var model: AppModel
    func body(content: Content) -> some View {
        content
            .onAppear { if model.steamSignedIn { model.loadSteamLibrary() } }
            .onChange(of: model.steamAccount) { model.resetSteamLibrary() }
            .onChange(of: model.steamSignedInAs) {
                model.resetSteamLibrary()
                if model.steamSignedIn { model.loadSteamLibrary() }
            }
    }
}
