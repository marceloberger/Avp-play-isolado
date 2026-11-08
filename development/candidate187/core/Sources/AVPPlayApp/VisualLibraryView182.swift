import AppKit
import AVPPlayCore
import SwiftUI

struct VisualLibraryView182: View {
    @EnvironmentObject private var model: AppModel
    @State private var entries: [LibraryEntry182] = []
    @State private var search = ""
    @State private var filter: LibraryStatus182?
    @State private var loading = true
    @State private var issue: String?
    @State private var inspection: LibraryEntry182?
    private var visible: [LibraryEntry182] { entries.filter { $0.matches(search: search, status: filter) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Sua próxima partida").font(.system(size: 34, weight: .bold, design: .rounded))
                        Text("\(entries.count) jogos com registros locais · AVP Play Candidate")
                            .foregroundStyle(.secondary)
                        Text("O status vem dos registros locais; esta tela não consulta o Vision Pro.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 10) {
                        Button("Importar jogo", systemImage: "plus") { model.autoImportLocalAPK() }
                            .buttonStyle(.borderedProminent).disabled(model.localImport.isRunning)
                        Button("Ver Jobs", systemImage: "list.bullet.clipboard") { model.section = .jobs }
                    }
                }
                HStack(spacing: 14) {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Pesquisar nome, pacote ou target", text: $search).textFieldStyle(.plain)
                    }.padding(12).background(.background).clipShape(RoundedRectangle(cornerRadius: 12))
                    Picker("Status", selection: $filter) {
                        Text("Todos os status").tag(Optional<LibraryStatus182>.none)
                        ForEach(LibraryStatus182.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
                    }.frame(width: 230)
                }
                if let issue { Label(issue, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                if loading { ProgressView("Lendo registros locais…") }
                else if visible.isEmpty {
                    ContentUnavailableView(search.isEmpty && filter == nil ? "Sua biblioteca começa aqui" : "Nenhum jogo encontrado",
                        systemImage: "gamecontroller", description: Text("Importe um APK ou uma pasta. Receitas de catálogo sem registros de importação não criam jogos nesta biblioteca."))
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 235, maximum: 310), spacing: 22)], alignment: .leading, spacing: 22) {
                    ForEach(visible) { entry in
                        LibraryGameCard182(entry: entry, progress: entry.activeJob.flatMap { model.copyProgress[$0.id] }, coverPaths: coverPaths(entry),
                            open: { open(entry) }, jobs: {
                                if entry.readOnly { inspection = entry }
                                else { model.selectedJob = entry.latestJob?.id; model.section = .jobs }
                            })
                    }
                }
            }.padding(30).frame(maxWidth: 1400, alignment: .leading).frame(maxWidth: .infinity)
        }.background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle("Minha biblioteca")
            .task(id: model.localLibraryRevision) { await reload() }
            .onChange(of: model.jobs) { _, _ in Task { await reload() } }
            .sheet(item: $inspection) { entry in ReadOnlyLibraryDetails182(entry: entry) }
    }
    @MainActor private func reload() async {
        guard let recipes = model.paths.recipes else { issue = "Diretório de receitas indisponível"; loading = false; return }
        let registry = model.localVariantStore, jobs = model.paths.jobs, root = DataLocation.base
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let legacyRoots = [support.appendingPathComponent("AVPPlay"), support.appendingPathComponent("AVPPlayModificado")]
        let result = await Task.detached(priority: .userInitiated) {
            Result { try VisualLibrary182.loadWithReadOnlySources(recipes: recipes, variants: registry, jobs: jobs,
                preparedRoot: root.appendingPathComponent("prepared-local"),
                provisionalRoot: root.appendingPathComponent("provisional-recipes"), otherRoots: legacyRoots) }
        }.value
        guard !Task.isCancelled else { return }
        loading = false
        switch result {
        case .success(let found): entries = found.entries; issue = found.warnings.isEmpty ? nil : found.warnings.joined(separator: "\n")
        case .failure(let error): issue = "Falha na leitura local: \(error)"
        }
    }
    private func coverPaths(_ entry: LibraryEntry182) -> [URL] {
        guard let recipe = entry.recipe else { return [] }
        return [Toolchain.storeCoverURL(store: model.paths.store, recipe: recipe)] + (recipe.catalogAppId.map {
            [CoverCache.defaultDirectory.appendingPathComponent($0 + ".jpg"), DataLocation.base.appendingPathComponent("covers/" + $0 + ".jpg")]
        } ?? [])
    }
    private func open(_ entry: LibraryEntry182) {
        if entry.readOnly { inspection = entry; return }
        if entry.recipe == nil && !entry.provisional {
            model.notice = "Registro de \(entry.package) encontrado sem receita correspondente. Nenhuma instalação foi inferida."
            return
        }
        if let recipe = entry.recipe, !model.localRecipes.contains(where: { $0.id == recipe.id }) {
            model.localRecipes.append(recipe) // in-memory detail navigation only
        }
        model.selectLocalLibraryItem(entry.id, isProvisional: entry.provisional)
        model.section = .localLibrary
    }
}

struct LibraryGameCard182: View {
    let entry: LibraryEntry182
    let progress: InstallProgress?
    var coverPaths: [URL] = []
    var open: () -> Void
    var jobs: () -> Void
    @State private var hovering = false
    private var color: Color {
        switch entry.status {
        case .installed: return .green
        case .prepared: return .blue
        case .pending: return .orange
        case .experimental: return .purple
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: open) {
                ZStack(alignment: .bottomLeading) {
                    LibraryCover182(entry: entry, paths: coverPaths).frame(height: 225).clipped()
                    LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                    Text(entry.title).font(.title3.bold()).foregroundStyle(.white).lineLimit(2).padding(16)
                }.frame(height: 225).clipped().overlay(alignment: .topLeading) {
                    Label(entry.status.rawValue, systemImage: entry.status == .installed ? "checkmark.circle.fill" : "circle.fill")
                        .font(.caption.bold()).padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule()).padding(12).foregroundStyle(color)
                }
            }.buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 10) {
                Text(entry.package.isEmpty ? entry.id : entry.package).font(.caption.monospaced()).lineLimit(1).textSelection(.enabled)
                Text(entry.target ?? "Target ainda não definido").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(entry.readOnly ? "\(entry.sourceLabel) · somente leitura" : "Registros do Candidate")
                    .font(.caption2).foregroundStyle(.secondary)
                if !entry.readOnly, let job = entry.activeJob {
                    Label(job.current == .stage ? "Transferência em andamento" : "Instalação / preparação em andamento",
                          systemImage: job.current == .stage ? "arrow.down.doc" : "gearshape.2")
                        .font(.caption).foregroundStyle(.tint)
                    if let progress, progress.total > 0 {
                        ProgressView(value: Double(min(progress.done, progress.total)), total: Double(progress.total))
                        Text("\(ByteCountFormatter.string(fromByteCount: progress.done, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: progress.total, countStyle: .file))")
                            .font(.caption2).foregroundStyle(.secondary)
                        if let file = progress.file { Text("Arquivos: \(file.index)/\(file.count)").font(.caption2) }
                        if let activity = progress.activity { Text(activity).font(.caption2).foregroundStyle(.secondary).lineLimit(3) }
                    } else { ProgressView().controlSize(.small) }
                }
                HStack {
                    Button("Detalhes", action: open)
                    Spacer()
                    Button("Jobs · \(entry.jobs.count)", action: jobs).disabled(entry.jobs.isEmpty)
                }.buttonStyle(.borderless)
            }.padding(14)
        }.background(.background).clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(hovering ? Color.accentColor.opacity(0.5) : .secondary.opacity(0.15)))
            .shadow(color: .black.opacity(hovering ? 0.12 : 0.05), radius: hovering ? 12 : 4, y: 3)
            .onHover { hovering = $0 }.help(entry.evidence)
    }
}

private struct LibraryCover182: View {
    let entry: LibraryEntry182
    let paths: [URL]
    @State private var artwork: NSImage?
    @State private var source = "Sem capa disponível · placeholder"
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.accentColor.opacity(0.35), .indigo.opacity(0.45), .black.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing)
            if let artwork { Image(nsImage: artwork).resizable().scaledToFill() }
            else { VStack(spacing: 12) { Image(systemName: "gamecontroller").font(.system(size: 45, weight: .light)); Text("SEM CAPA").font(.caption2.monospaced()).tracking(3) }.foregroundStyle(.white.opacity(0.65)) }
        }.help(source).accessibilityLabel("Capa de \(entry.title). \(source)")
            .task(id: entry.id) {
                let cache = LibraryArtwork182(), appID = entry.recipe?.catalogAppId ?? entry.artworkAppID
                let bundled = Bundle.main.resourceURL.map { LibraryArtwork182(directory: $0.appendingPathComponent("library-artwork182")) }
                var found = appID.flatMap { bundled?.cached(appID: $0) }
                if found == nil { found = await Task.detached { cache.existing(appID: appID, paths: paths) }.value }
                if found == nil, let appID { found = await cache.fetchOfficial(appID: appID) }
                guard !Task.isCancelled else { return }
                if let found, let image = NSImage(data: found.data) {
                    artwork = image; source = found.origin.source + " · " + (found.origin.page ?? found.origin.image)
                }
            }
    }
}


private struct ReadOnlyLibraryDetails182: View {
    @Environment(\.dismiss) private var dismiss
    let entry: LibraryEntry182
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(entry.title).font(.title.bold())
            Label("\(entry.sourceLabel) · somente leitura", systemImage: "lock.doc")
            Text("Este registro pertence a outra biblioteca local. Nenhuma instalação foi criada ou migrada para o Candidate. As ações de instalação e transferência não ficam disponíveis nesta visualização.")
                .foregroundStyle(.secondary)
            LabeledContent("Pacote", value: entry.package)
            LabeledContent("Target", value: entry.target ?? "Não identificado")
            LabeledContent("Variantes registradas", value: String(entry.variantCount))
            LabeledContent("Estado local", value: entry.status.rawValue)
            Text(entry.evidence).font(.caption).foregroundStyle(.secondary)
            if !entry.jobs.isEmpty {
                Text("Jobs da origem").font(.headline)
                ForEach(entry.jobs) { job in Text("\(job.id) · \(job.state.rawValue)").font(.caption.monospaced()) }
            }
            Button("Fechar") { dismiss() }.keyboardShortcut(.cancelAction)
        }.padding(28).frame(width: 560).textSelection(.enabled)
    }
}
