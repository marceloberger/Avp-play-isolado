import AppKit
import AVPPlayCore
import SwiftUI

/// Die Datenverwaltung: was heruntergeladen ist, wie viel Platz es belegt, und wie man es wieder loswird.
struct DataView: View {
    @EnvironmentObject var model: AppModel
    @State private var removing: StoredGame?
    @State private var removalPlan: StoreDownloadRemoval?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox(L("Downloads Folder", "Ordner für Downloads")) {
                    VStack(alignment: .leading, spacing: 8) {
                        StoreLocationBox()
                        if let storage = model.storage, storage.available, model.storeMove == nil {
                            Text(summary(storage)).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }

                GroupBox(L("Downloaded Games", "Heruntergeladene Spiele")) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text(L("Which folder belongs to which game is also written in “\(StoreIndex.fileName)” in the downloads folder.",
                                   "Welcher Ordner zu welchem Spiel gehört, steht auch in „\(StoreIndex.fileName)“ im Ordner für Downloads."))
                                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button(L("Export Game List …", "Spieleliste exportieren …")) { model.exportGameList() }.controlSize(.small)
                                .help(L("A text file with your downloaded games, the games in your Meta account and your favourites – to pass on, for example to the project.",
                                        "Eine Textdatei mit deinen geladenen Spielen, den Spielen in deinem Meta-Konto und deinen Favoriten – zum Weitergeben, etwa an das Projekt."))
                        }
                        .padding(6)
                        Divider()
                        if let storage = model.storage {
                            if storage.games.isEmpty {
                                Text(storage.available ? L("Nothing has been downloaded yet.", "Noch ist nichts heruntergeladen.")
                                                       : L("The folder cannot be read at the moment.", "Der Ordner lässt sich gerade nicht lesen."))
                                    .foregroundStyle(.secondary).padding(6)
                            }
                            ForEach(storage.games) { item in
                                StoredGameRow(item: item, gameTotal: model.storage?.inventory?.games.first(where: { $0.title == item.title })) {
                                    if let plan = model.storeRemovalPlan(item), !plan.files.isEmpty {
                                        removalPlan = plan; removing = item
                                    } else { model.notice = "Não há downloads removíveis nesta pasta. APKs, metadados, recibos e subpastas são preservados." }
                                }
                                if item.id != storage.games.last?.id { Divider() }
                            }
                        } else {
                            HStack { ProgressView().controlSize(.small); Text(L("Counting …", "Wird gezählt …")).foregroundStyle(.secondary) }.padding(6)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let storage = model.storage {
                    GroupBox(L("Other Data on This Mac", "Weitere Daten auf diesem Mac")) {
                        VStack(alignment: .leading, spacing: 6) {
                            DisclosureGroup {
                                Text(toolchainText(storage)).font(.callout).foregroundStyle(.secondary)
                                if !storage.toolchains.isEmpty {
                                    ForEach(storage.toolchains) { toolchain in
                                        HStack { Text("Toolchain \(toolchain.version) · \(toolchain.commit)"); Spacer(); Text(StoredGameRow.size(toolchain.bytes)).monospacedDigit() }
                                            .font(.callout).padding(.leading, 18)
                                    }
                                }
                            } label: {
                                inventoryLabel("Toolchains", bytes: storage.toolchains.map(\.bytes).reduce(0, +), count: storage.toolchains.count)
                            }
                            DisclosureGroup {
                                Text("Store cover images cache").font(.callout).foregroundStyle(.secondary)
                            } label: {
                                inventoryLabel("Pictures from the Meta Store", bytes: storage.pictureCache, count: 0)
                            }
                            if let inventory = storage.inventory {
                                StorageInventoryView(inventory: inventory)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }
                }
                Text("Show revela exatamente a pasta indicada. Remove atua somente sobre arquivos de download não APK listados na confirmação; preserva subpastas, variantes, builds, Jobs, recibos e backups. A remoção não afeta o Vision Pro.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(L("Data", "Datenverwaltung"))
        .task { model.scanStorage() }
        .sheet(item: $removing) { item in
            if let plan = removalPlan {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Remover downloads de \(item.title)?").font(.title2.bold())
                    Text(plan.directory.path).font(.caption).textSelection(.enabled)
                    Text("Somente os \(plan.files.count) arquivos abaixo (\(StoredGameRow.size(plan.bytes)) por tamanho lógico) serão removidos. \(plan.preservedFiles) arquivos nesta pasta serão preservados. O espaço físico liberado pode ser menor devido a clones/links/snapshots.")
                    Text("APKs, subpastas, variantes, builds funcionais, Jobs, recibos e backups não fazem parte desta exclusão.")
                        .font(.callout).foregroundStyle(.secondary)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(plan.files, id: \.path) { file in Text(file.lastPathComponent).font(.caption.monospaced()).textSelection(.enabled) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(minHeight: 140, maxHeight: 300)
                    HStack {
                        Spacer()
                        Button("Cancelar") { removing = nil; removalPlan = nil }
                        Button("Remover somente estes downloads", role: .destructive) {
                            model.removeStored(item, plan: plan, approved: true); removing = nil; removalPlan = nil
                        }
                    }
                }.padding(24).frame(width: 620)
            }
        }
    }

    private func summary(_ storage: StorageOverview) -> String {
        let n = storage.games.count
        let used = "\(n) pastas no store · \(StoredGameRow.size(storage.gamesBytes)) em referências lógicas (inclui metadados ocultos). APKs locais e builds aparecem nas categorias abaixo."
        guard let free = storage.freeBytes else { return used }
        return used + L(" · \(Installer.gigabytes(free)) free on this disk", " · \(Installer.gigabytes(free)) frei auf dieser Platte")
    }

    private func inventoryLabel(_ title: String, bytes: Int64, count: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            if count > 0 { Text("\(count)").foregroundStyle(.secondary).monospacedDigit() }
            Text(StoredGameRow.size(bytes)).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private func toolchainText(_ storage: StorageOverview) -> String {
        let all = storage.toolchains.map(\.bytes).reduce(0, +)
        let older = storage.olderToolchains
        // Die Zahl ist die Summe der Dateigrößen. Beim Bauen entstehen Kopien, die sich auf dem Startlaufwerk den Platz
        // mit den Downloads teilen können; frei wird dann weniger, als hier steht.
        let base = L("\(storage.toolchains.count) installed, \(Installer.gigabytes(all)) by file size (they grow with every game that is built; part of it can share disk space with the downloads).",
                     "\(storage.toolchains.count) installiert, nach Dateigröße \(Installer.gigabytes(all)) (sie wachsen mit jedem Spiel, das gebaut wird; ein Teil kann sich den Platz mit den Downloads teilen).")
        guard !older.isEmpty else { return base }
        return base + L(" \(older.count) of them are older versions that nothing needs any more: \(Installer.gigabytes(older.map(\.bytes).reduce(0, +))).",
                        " \(older.count) davon sind ältere Fassungen, die nichts mehr braucht: \(Installer.gigabytes(older.map(\.bytes).reduce(0, +))).")
    }
}

/// Eine Zeile der Datenverwaltung: ein Spiel mit dem, was von ihm auf dem Mac liegt, aufklappbar bis zur Datei.
struct StoredGameRow: View {
    @EnvironmentObject var model: AppModel
    let item: StoredGame
    var gameTotal: GameStorageTotal? = nil
    let remove: () -> Void
    @State private var open = false

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: 3) {
                if let total = gameTotal {
                    HStack {
                        Text("Total associado neste Mac")
                        if total.partial { Text("· parcial").foregroundStyle(.orange) }
                        Spacer()
                        Text(Self.size(total.bytes)).monospacedDigit()
                    }
                    .font(.callout).padding(.bottom, 4)
                }
                ForEach(item.files.prefix(200)) { file in
                    HStack {
                        Image(systemName: file.isFolder ? "folder" : "doc").foregroundStyle(.secondary).frame(width: 18)
                        Text(file.name).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(Self.size(file.bytes)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .font(.callout)
                }
                if item.files.count > 200 {
                    Text(L("… and \(item.files.count - 200) more", "… und \(item.files.count - 200) weitere")).font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 4).padding(.vertical, 6)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.headline).lineLimit(1)
                    Text(L("\(item.detail) · \(item.fileCount) \(item.fileCount == 1 ? "file" : "files")", "\(item.detail) · \(item.fileCount) \(item.fileCount == 1 ? "Datei" : "Dateien")"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Text(Self.size(item.bytes)).monospacedDigit()
                Button(L("Show", "Zeigen")) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }.controlSize(.small)
                Button(L("Remove …", "Entfernen …"), role: .destructive, action: remove).controlSize(.small)
                    .disabled(model.storeMove != nil || (item.gameId.map { model.isBusy($0) || model.steamBusy.contains($0) } ?? false))
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 6)
    }

    static func size(_ bytes: Int64) -> String {
        bytes >= 1_000_000_000 ? Installer.gigabytes(bytes)
            : bytes >= 1_000_000 ? String(format: "%.2f MB", Double(bytes) / 1e6)
            : bytes >= 1_000 ? String(format: "%.2f KB", Double(bytes) / 1e3) : "\(bytes) bytes"
    }
}
