import AppKit
import AVPPlayCore
import SwiftUI

/// Ein Ordner im Bestand: die heruntergeladenen Dateien eines Spiels in einer Fassung.
struct StoredGame: Identifiable {
    struct File: Identifiable {
        let name: String
        let bytes: Int64
        let isFolder: Bool
        var id: String { name }
    }
    /// Der Ordnername im Bestand.
    let id: String
    let url: URL
    let title: String
    let detail: String
    let bytes: Int64
    let fileCount: Int
    /// Was direkt im Ordner liegt, das Größte zuerst.
    let files: [File]
    /// Das Spiel der Übersicht, zu dem der Ordner gehört; `nil`, wenn ihn kein Rezept mehr braucht.
    let gameId: String?
}

struct StoredToolchain: Identifiable {
    let version: Int
    let commit: String
    let url: URL
    let bytes: Int64
    let inUse: Bool
    var id: Int { version }
}

/// Was auf diesem Mac an Daten liegt.
struct StorageOverview {
    var root: URL
    var isCustom: Bool
    var available: Bool
    var games: [StoredGame]
    var freeBytes: Int64?
    var toolchains: [StoredToolchain]
    /// Was von einem abgebrochenen Abruf bei SteamCMD liegen geblieben ist.
    var steamLeftover: Int64
    /// Der Zwischenspeicher der Titelbilder aus dem Store.
    var pictureCache: Int64 = 0

    var inventory: LocalStorageInventory?

    var gamesBytes: Int64 { games.map(\.bytes).reduce(0, +) }
    var olderToolchains: [StoredToolchain] { toolchains.filter { !$0.inUse } }
}

/// Die Datenverwaltung: sehen, was heruntergeladen ist, es entfernen, und den Ort dafür wechseln.
extension AppModel {
    /// Lässt sich der Ordner für Downloads gerade benutzen? Nicht, während er umzieht, und nicht, wenn seine Platte
    /// nicht angeschlossen ist – sonst sähe es aus, als fehlten alle Dateien, und sie würden neu geladen.
    var storeBlocker: String? {
        if storeMove != nil {
            return L("The downloads are being moved to another folder. Wait until that has finished.", "Die Downloads ziehen gerade in einen anderen Ordner um. Warte, bis das fertig ist.")
        }
        if !StoreLocation.isAvailable(paths.store.root) {
            return L("The downloads folder cannot be reached – is the disk connected? (\(paths.store.root.path))",
                     "Der Ordner für Downloads ist nicht erreichbar – ist die Platte angeschlossen? (\(paths.store.root.path))")
        }
        return nil
    }

    /// Sieht nach, was im Bestand liegt. Das Zählen läuft im Hintergrund: Es sind schnell über hundert Gigabyte
    /// in zehntausenden Dateien.
    func scanStorage() {
        guard !storageScanning else { return }
        storageScanning = true
        let paths = paths
        let variants = localVariantStore
        let inventoryRecipes = Array(Dictionary((localRecipes + games.map(\.recipe) + jobs.map(\.recipe)).map { ($0.id + ":" + String($0.versionCode), $0) }, uniquingKeysWith: { first, _ in first }).values)
        let known = games.map { (id: $0.id, folder: "\($0.recipe.id)-\($0.recipe.versionCode)", recipe: $0.recipe.id, title: $0.recipe.title, version: $0.recipe.versionName) }
        let unfinished = Set(jobs.filter { $0.state != .finished && $0.state != .cancelled }.map(\.toolchainCommit))
            .union(keptToolchainCommits)
        Task.detached {
            let fm = FileManager.default
            let root = paths.store.root
            var stored: [StoredGame] = []
            for url in StoreMove.items(in: root) where !url.lastPathComponent.hasPrefix(".") {
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                let name = url.lastPathComponent
                let entries = ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
                    .filter { !$0.lastPathComponent.hasPrefix(".") }
                let files = entries.map { entry -> StoredGame.File in
                    let folder = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                    return StoredGame.File(name: entry.lastPathComponent, bytes: StoreMove.measure(entry).bytes, isFolder: folder)
                }.sorted { $0.bytes > $1.bytes }
                let size = StoreMove.measure(url)
                let title: String, detail: String, gameId: String?
                if let game = known.first(where: { $0.folder == name }) {
                    (title, detail, gameId) = (game.title, L("Version \(game.version)", "Version \(game.version)"), game.id)
                } else if let game = known.first(where: { name.hasPrefix($0.recipe + "-") }) {
                    (title, detail, gameId) = (game.title, L("An earlier version – no longer needed", "Eine frühere Fassung – wird nicht mehr gebraucht"), nil)
                } else {
                    (title, detail, gameId) = (name, L("Not used by any game in the list", "Von keinem Spiel der Liste gebraucht"), nil)
                }
                stored.append(StoredGame(id: name, url: url, title: title, detail: detail, bytes: size.bytes, fileCount: size.files, files: files, gameId: gameId))
            }
            stored.sort { $0.bytes > $1.bytes }

            let installed = paths.packager.installed()
            let toolchains = installed.enumerated().compactMap { index, toolchain -> StoredToolchain? in
                guard let manifest = toolchain.manifest else { return nil }
                let needed = index == 0 || unfinished.contains { !$0.isEmpty && (manifest.commit.hasPrefix($0) || $0.hasPrefix(manifest.commit)) }
                return StoredToolchain(version: manifest.version, commit: manifest.commit, url: toolchain.root,
                                       bytes: StoreMove.measure(toolchain.root).bytes, inUse: needed)
            }
            var steam = StoreMove.measure(SteamTool().directory.appendingPathComponent("steamapps/content")).bytes
            steam += StoreMove.measure(root.appendingPathComponent(".steamcmd/content")).bytes

            let inventory = LocalStorageInventory.scan(store: paths.store, variants: variants, recipes: inventoryRecipes,
                cache: DataLocation.isCandidate(bundleIdentifier: DataLocation.runningBundleIdentifier)
                    ? DataLocation.base.appendingPathComponent("cache")
                    : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/AVPPlayModificado"),
                temporary: DataLocation.temporaryDirectory)
            let overview = StorageOverview(
                root: root, isCustom: StoreLocation.custom() != nil, available: StoreLocation.isAvailable(root), games: stored,
                freeBytes: StoreLocation.freeBytes(at: root),
                toolchains: toolchains, steamLeftover: steam, pictureCache: CoverCache().size(), inventory: inventory)
            await MainActor.run {
                self.storage = overview
                self.storageScanning = false
            }
        }
    }

    /// Entfernt die heruntergeladenen Dateien eines Eintrags von diesem Mac. Was auf der Vision Pro installiert
    /// ist, bleibt dort.
    func storeRemovalPlan(_ item: StoredGame) -> StoreDownloadRemoval? {
        guard let recipe = (localRecipes + games.map(\.recipe) + jobs.map(\.recipe)).first(where: {
            "\($0.id)-\($0.versionCode)" == item.id
        }) else { notice = "Receita da pasta não identificada. Use Show para inspecionar; exclusão automática bloqueada."; return nil }
        do { return try StoreDownloadRemoval(store: paths.store, recipe: recipe, variants: localVariantStore) }
        catch { notice = "\(error)"; return nil }
    }

    func removeStored(_ item: StoredGame, plan: StoreDownloadRemoval, approved: Bool) {
        guard approved, storeMove == nil, runningJob == nil, queued.isEmpty, steamBusy.isEmpty,
              plan.directory.standardizedFileURL == item.url.standardizedFileURL else {
            notice = "Exclusão cancelada ou bloqueada enquanto há Jobs ativos."; return
        }
        // Only regular files are unlinked. Keep admission and deletion on the same actor so a Job
        // cannot start between the busy guard and removal; no recursive deletion or large file reads.
        do {
            try plan.remove(approved: approved)
            notice = "\(plan.files.count) arquivos de downloads removidos. APKs, recibos, biblioteca e builds preservados."
        } catch { notice = "\(error)" }
        refresh(); scanStorage()
    }

    /// Entfernt die Toolchains, die keiner mehr braucht: alle bis auf die neueste, die, mit denen ein noch
    /// nicht abgeschlossener Auftrag begonnen wurde, und die, die für ein Spiel gewählt sind.
    func removeOlderToolchains() {
        notice = "Toolchains e fontes de builds foram preservados. Use Show para inspecionar; esta tela não apaga artefatos ou dependências do histórico."
    }

    func removePictureCache() {
        let cache = CoverCache()
        let alert = NSAlert(); alert.messageText = "Remover somente o cache de imagens?"
        alert.informativeText = "\(cache.directory.path)\nAs imagens poderão ser obtidas novamente. APKs, variantes, builds, Jobs e recibos serão preservados."
        alert.addButton(withTitle: "Remover imagens"); alert.addButton(withTitle: "Cancelar")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task.detached { cache.clear(); await MainActor.run { self.scanStorage() } }
    }

    func removeSteamLeftovers() {
        // This directory may contain user-provided games. Keep it read-only in Data.
        notice = "Arquivos temporários Steam podem conter dados de jogos. Use Show para inspecionar; exclusão automática desativada nesta tela."
    }

    // MARK: Den Ort wechseln

    /// Fragt nach einem Ordner und zieht die Downloads dorthin um.
    func chooseStoreLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = L("Use This Folder", "Diesen Ordner verwenden")
        panel.message = L("Choose where downloaded games are kept – for example on an external disk. The app creates a folder “\(StoreLocation.folderName)” in it.",
                          "Wähle, wo heruntergeladene Spiele liegen sollen – zum Beispiel auf einer externen Platte. Die App legt darin einen Ordner „\(StoreLocation.folderName)“ an.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        moveStore(to: StoreLocation.folder(in: url))
    }

    /// Zurück an den üblichen Ort neben den Daten des Programms.
    func useStandardStoreLocation() { moveStore(to: StoreLocation.standard()) }

    /// Zieht den Bestand um und stellt danach auf den neuen Ort um. Bestätigt wird vorher, mit der Größe.
    func moveStore(to target: URL, confirm: Bool = true) {
        guard DataLocation.isIsolated(target, bundleIdentifier: DataLocation.runningBundleIdentifier) else {
            storeMoveNote = StoreLocationError.sharedWithOfficial.localizedDescription
            return
        }
        let old = paths.store.root
        guard target.standardizedFileURL.path != old.standardizedFileURL.path else { return }
        guard storeMove == nil else { return }
        guard runningJob == nil, queued.isEmpty, steamBusy.isEmpty else {
            storeMoveNote = L("A job is running. Change the folder when it has finished.", "Es läuft gerade ein Auftrag. Wechsle den Ordner, wenn er fertig ist.")
            return
        }
        guard StoreLocation.isAvailable(target) else {
            storeMoveNote = "\(StoreMoveError.notAvailable(target.path))"
            return
        }
        storeMoveNote = L("Looking at what has to move …", "Es wird nachgesehen, was umziehen muss …")
        let stops = storeMoveStop
        stops.clear("store")
        Task {
            let total: Int64 = await Task.detached { StoreMove.items(in: old).map { StoreMove.measure($0).bytes }.reduce(0, +) }.value
            // Platz am Ziel, wenn es ein anderes Laufwerk ist.
            if !StoreLocation.sameVolume(old, target) {
                if let free = StoreLocation.freeBytes(at: target), total + 1_000_000_000 > free {
                    storeMoveNote = L("Not enough space there: \(Installer.gigabytes(total)) have to move, \(Installer.gigabytes(free)) are free.",
                                      "Dort ist zu wenig Platz: \(Installer.gigabytes(total)) müssen umziehen, \(Installer.gigabytes(free)) sind frei.")
                    return
                }
            }
            if confirm {
                let alert = NSAlert()
                alert.messageText = L("Move the downloads?", "Downloads umziehen?")
                alert.informativeText = L("\(Installer.gigabytes(total)) of downloaded games move to\n\(target.path)\n\nEach game is removed from the old place only once it has arrived completely. Installing is paused meanwhile.",
                                          "\(Installer.gigabytes(total)) heruntergeladene Spiele ziehen um nach\n\(target.path)\n\nJedes Spiel wird am alten Ort erst gelöscht, wenn es vollständig angekommen ist. Installieren ist währenddessen angehalten.")
                alert.addButton(withTitle: L("Move", "Umziehen"))
                alert.addButton(withTitle: L("Cancel", "Abbrechen"))
                guard alert.runModal() == .alertFirstButtonReturn else { storeMoveNote = nil; return }
            }
            storeMove = StoreMove.Progress(done: 0, total: total, item: "")
            storeMoveNote = nil
            let activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .suddenTerminationDisabled], reason: "Moving downloads")
            let outcome: Result<StoreMove.Result, Error> = await Task.detached {
                Result {
                    try StoreMove.run(from: old, to: target, shouldStop: { stops.isRequested("store") }) { progress in
                        Task { @MainActor in if self.storeMove != nil { self.storeMove = progress } }
                    }
                }
            }.value
            ProcessInfo.processInfo.endActivity(activity)
            // Kurz warten, damit eine noch unterwegs befindliche Zwischenmeldung den Schluss nicht überschreibt.
            try? await Task.sleep(for: .milliseconds(200))
            storeMove = nil
            switch outcome {
            case .success(let result):
                do {
                    try StoreLocation.set(target)
                    paths = Paths()
                    // Die Spielstände liegen neben dem Ordner für Downloads und ziehen mit ihm um.
                    let (from, to) = (SaveStore.root(forStore: old), SaveStore.root(forStore: target))
                    await Task.detached { _ = SaveStore.move(from: from, to: to) }.value
                    storeMoveNote = result.skipped.isEmpty
                        ? L("Done. Downloads are now kept in \(target.path).", "Fertig. Downloads liegen jetzt in \(target.path).")
                        : L("Done. Downloads are now kept in \(target.path). Already present there and therefore left at the old place: \(result.skipped.joined(separator: ", ")).",
                            "Fertig. Downloads liegen jetzt in \(target.path). Dort schon vorhanden und deshalb am alten Ort geblieben: \(result.skipped.joined(separator: ", ")).")
                } catch {
                    storeMoveNote = error.localizedDescription
                }
            case .failure(let error):
                // Ein Teil kann schon drüben sein. Der alte Ort gilt weiter; derselbe Umzug noch einmal holt den Rest.
                storeMoveNote = L("\(error) The old folder is still the one in use. What has already moved is waiting at the new place – choose the same folder again to move the rest.",
                                  "\(error) Es gilt weiter der alte Ordner. Was schon umgezogen ist, wartet am neuen Ort – wähle denselben Ordner noch einmal, um den Rest zu holen.")
            }
            refresh()
            scanStorage()
        }
    }

    func stopStoreMove() { storeMoveStop.request("store") }
}

/// Der Ort der Downloads mit dem, was sich daran ändern lässt – auf der Seite „Datenverwaltung“ und in den Einstellungen.
struct StoreLocationBox: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let root = model.paths.store.root
        VStack(alignment: .leading, spacing: 8) {
            Text(root.path).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !StoreLocation.isAvailable(root) {
                Label(L("This folder cannot be reached – is the disk connected? Nothing is downloaded until it is.",
                        "Dieser Ordner ist nicht erreichbar – ist die Platte angeschlossen? Bis dahin wird nichts geladen."),
                      systemImage: "externaldrive.badge.exclamationmark").foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let move = model.storeMove {
                ProgressView(value: Double(move.done), total: Double(max(move.total, 1)))
                HStack {
                    Text(move.item.isEmpty ? L("Moving …", "Umzug läuft …")
                         : L("Moving \(move.item) … \(Installer.gigabytes(move.done)) of \(Installer.gigabytes(move.total))",
                             "\(move.item) zieht um … \(Installer.gigabytes(move.done)) von \(Installer.gigabytes(move.total))"))
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button(L("Stop", "Anhalten")) { model.stopStoreMove() }.controlSize(.small)
                }
            } else {
                HStack {
                    Button(L("Change …", "Ändern …")) { model.chooseStoreLocation() }
                    if StoreLocation.custom() != nil {
                        Button(L("Use Default Folder", "Üblichen Ordner verwenden")) { model.useStandardStoreLocation() }
                    }
                    Button(L("Show in Finder", "Im Finder zeigen")) { NSWorkspace.shared.activateFileViewerSelecting([root]) }
                        .disabled(!FileManager.default.fileExists(atPath: root.path))
                }
            }
            if let note = model.storeMoveNote {
                Text(note).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
    }
}
