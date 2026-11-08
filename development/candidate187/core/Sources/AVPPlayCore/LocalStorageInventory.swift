import Foundation
import Darwin

public enum LocalStorageCategory: String, Codable, CaseIterable, Sendable {
    case store, library, builds, cache
    public var title: String {
        switch self {
        case .store: return "Downloads na pasta store"
        case .library: return "Biblioteca local e referências externas"
        case .builds: return "Builds compilados, assinados e toolchains"
        case .cache: return "Caches e workspaces temporários"
        }
    }
}
public struct LocalStorageEntry: Codable, Sendable, Identifiable {
    public var id: String { category.rawValue + ":" + url.path }
    public var category: LocalStorageCategory
    public var title: String
    public var url: URL
    public var files: Int = 0
    public var referencedBytes: Int64 = 0
    /// One file identity per device/inode, allocated once across the whole inventory.
    /// Not physical allocation or an estimate of reclaimable space (partial clones/snapshots may share blocks).
    public var uniqueBytes: Int64 = 0
    public var sharedBytes: Int64 = 0
    public var available: Bool = true
    public var issues: [String] = []
}
public struct LocalStorageInventory: Codable, Sendable {
    public var entries: [LocalStorageEntry]
    public var games: [GameStorageTotal] = []
    /// Shared across games or without proven ownership; never assigned to the first game visited.
    public var unassignedBytes: Int64 = 0
    public var uniqueLogicalBytes: Int64 { entries.reduce(0) { $0 + $1.uniqueBytes } }

    struct Root {
        var category: LocalStorageCategory
        var title: String
        var url: URL
        var excluding: [URL] = []
    }
    static func scan(roots: [Root], ownership: GameStorageOwnership = GameStorageOwnership()) -> LocalStorageInventory {
        var seen: Set<String> = [], entries: [LocalStorageEntry] = []
        struct FileOwners { var bytes: Int64; var ids: Set<String>; var unknown: Bool }
        var files: [String: FileOwners] = [:], present: Set<String> = [], partial: Set<String> = []
        for root in roots {
            var entry = LocalStorageEntry(category: root.category, title: root.title, url: root.url)
            let exclusions = root.excluding.map { $0.standardizedFileURL.path }
            func excluded(_ file: URL) -> Bool {
                let path = file.standardizedFileURL.path
                return exclusions.contains { path == $0 || path.hasPrefix($0 + "/") }
            }
            func count(_ file: URL) {
                guard !excluded(file) else { return }
                var st = stat()
                guard lstat(file.path, &st) == 0 else {
                    entry.issues.append("Não foi possível ler \(file.path)")
                    partial.formUnion(ownership.owners(of: file)); return
                }
                guard st.st_mode & S_IFMT == S_IFREG else { return } // Never follow symlinks.
                // Clone IDs can survive partial copy-on-write changes. They do not prove equal content.
                // Count hard links/overlapping paths once; report clones as separate logical files.
                let key = "\(st.st_dev):inode:\(st.st_ino)"
                entry.files += 1; entry.referencedBytes += st.st_size
                let owners = ownership.owners(of: file)
                present.formUnion(owners)
                if var previous = files[key] {
                    previous.ids.formUnion(owners); previous.unknown = previous.unknown || owners.isEmpty
                    if previous.bytes != st.st_size { partial.formUnion(previous.ids) }
                    files[key] = previous
                } else { files[key] = FileOwners(bytes: st.st_size, ids: owners, unknown: owners.isEmpty) }
                if seen.insert(key).inserted { entry.uniqueBytes += st.st_size }
                else { entry.sharedBytes += st.st_size }
            }
            var st = stat()
            if lstat(root.url.path, &st) != 0 { entry.available = false }
            else if st.st_mode & S_IFMT == S_IFREG { count(root.url) }
            else if st.st_mode & S_IFMT == S_IFDIR {
                if let walker = FileManager.default.enumerator(at: root.url, includingPropertiesForKeys: [.isSymbolicLinkKey],
                    errorHandler: { url, _ in entry.issues.append("Não foi possível listar \(url.path)"); return true }) {
                    for case let file as URL in walker {
                        if excluded(file) { walker.skipDescendants(); continue }
                        if (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                            entry.issues.append("Link simbólico não seguido: \(file.path)")
                            partial.formUnion(ownership.owners(of: file)); walker.skipDescendants(); continue
                        }
                        count(file)
                    }
                } else { entry.available = false }
            } else { entry.available = false; entry.issues.append("Link simbólico ou tipo sem suporte; não seguido.") }
            let owners = ownership.owners(of: root.url)
            present.formUnion(owners)
            if !entry.available || !entry.issues.isEmpty { partial.formUnion(owners) }
            entries.append(entry)
        }
        var totals: [String: Int64] = [:], unassigned: Int64 = 0
        for file in files.values {
            if file.ids.count == 1, !file.unknown, let id = file.ids.first {
                totals[id, default: 0] += file.bytes
            } else {
                unassigned += file.bytes
                partial.formUnion(file.ids)
            }
        }
        let games = present.map { id in GameStorageTotal(id: id, title: ownership.titles[id] ?? id,
            bytes: totals[id] ?? 0, partial: partial.contains(id)) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return LocalStorageInventory(entries: entries, games: games, unassignedBytes: unassigned)
    }

    public static func scan(base: URL = DataLocation.base, store: ContentStore,
                            variants: LocalAPKVariantStore, recipes: [Recipe], cache: URL,
                            temporary: URL? = nil) -> LocalStorageInventory {
        let fm = FileManager.default
        func children(_ url: URL) -> [URL] { ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []).sorted { $0.path < $1.path } }
        var roots: [Root] = []
        for game in children(store.root) where !game.lastPathComponent.hasPrefix(".") && game.hasDirectoryPath {
            roots.append(Root(category: .store, title: game.lastPathComponent, url: game))
        }
        var external: Set<URL> = [], origins: Set<URL> = [], variantFolders: Set<URL> = []
        for folder in children(variants.root) where folder.hasDirectoryPath && !folder.lastPathComponent.hasPrefix(".") && folder.lastPathComponent != "learned-recipes" {
            guard (try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { continue }
            variantFolders.insert(folder)
            for metadata in children(folder) where metadata.pathExtension == "json" {
                guard let data = try? Data(contentsOf: metadata), let variant = try? JSONDecoder().decode(LocalAPKVariant.self, from: data) else { continue }
                external.formUnion((variant.assets ?? []).map { URL(fileURLWithPath: $0.sourcePath) })
                if let original = variant.originalAPKSourcePath { origins.insert(URL(fileURLWithPath: original)) }
                else if let source = variant.sourceRootPath {
                    // Legacy records did not retain the original APK path. Find same-size APK candidates only;
                    // this inventories paths, it does not claim they are the imported APK or trust their hash.
                    if let walker = fm.enumerator(at: URL(fileURLWithPath: source), includingPropertiesForKeys: [.isSymbolicLinkKey]) {
                        var visited = 0
                        for case let file as URL in walker {
                            visited += 1; if visited > 100_000 { break }
                            if (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { walker.skipDescendants(); continue }
                            if file.pathExtension.lowercased() == "apk", ContentStore.fileSize(file) == variant.size { origins.insert(file) }
                        }
                    }
                }
            }
        }
        // Include orphaned/older library folders even when their recipes are no longer in the catalog.
        for folder in children(variants.root) where folder.hasDirectoryPath && !folder.lastPathComponent.hasPrefix(".") && folder.lastPathComponent != "learned-recipes" {
            variantFolders.insert(folder)
        }
        for folder in variantFolders.sorted(by: { $0.path < $1.path }) {
            let title = recipes.first { "\($0.id)-\($0.versionCode)" == folder.lastPathComponent }?.title ?? folder.lastPathComponent
            roots.append(Root(category: .library, title: "APK importado e metadados · \(title)", url: folder))
        }
        for file in origins.sorted(by: { $0.path < $1.path }) { roots.append(Root(category: .library, title: "APK de origem encontrado (identidade não inferida) · \(file.lastPathComponent)", url: file)) }
        for file in external.sorted(by: { $0.path < $1.path }) { roots.append(Root(category: .library, title: "Dados externos referenciados · \(file.lastPathComponent)", url: file)) }
        roots.append(Root(category: .library, title: "Histórico, confirmações e recibos", url: variants.root.appendingPathComponent("learned-recipes")))
        roots.append(Root(category: .library, title: "Jobs e logs preservados", url: base.appendingPathComponent("jobs")))
        var workspaceRemainders: [Root] = []
        for name in ["build-only", "compiled-games"] {
            for workspace in children(base.appendingPathComponent(name)) {
                let id = String(workspace.lastPathComponent.suffix(36))
                guard UUID(uuidString: id) != nil else { continue }
                let products = workspace.appendingPathComponent("visionos/build/avpplay-build-only/\(id)/DerivedData/Build/Products/Debug-xros")
                let apps = children(products).filter { $0.pathExtension == "app" }
                for app in apps { roots.append(Root(category: .builds, title: "Build compilado · \(workspace.lastPathComponent)", url: app)) }
                var prepared: [URL] = []
                for folder in children(workspace) where fm.fileExists(atPath: folder.appendingPathComponent(".qi-prepared").path) {
                    prepared.append(folder)
                    roots.append(Root(category: .library, title: "Assets e dados preparados · \(workspace.lastPathComponent)/\(folder.lastPathComponent)", url: folder))
                }
                workspaceRemainders.append(Root(category: .cache, title: "Workspace: fontes/intermediários preservados · \(workspace.lastPathComponent)", url: workspace, excluding: apps + prepared))
            }
        }
        for folder in children(base.appendingPathComponent("signed-existing")) {
            for app in children(folder).filter({ $0.pathExtension == "app" }) { roots.append(Root(category: .builds, title: "Build assinado · \(folder.lastPathComponent)", url: app)) }
        }
        for name in ["toolchains", "klepton-overlays"] {
            for folder in children(base.appendingPathComponent(name)) { roots.append(Root(category: .builds, title: "Toolchain/fontes preservadas · \(folder.lastPathComponent)", url: folder)) }
        }
        roots += workspaceRemainders
        for url in [cache, base.appendingPathComponent(".sha256-cache"), variants.root.appendingPathComponent(".sha256-cache"),
                    store.root.appendingPathComponent(".steamcmd/content"), base.appendingPathComponent("tools/steamcmd/steamapps/content")] {
            if fm.fileExists(atPath: url.path) { roots.append(Root(category: .cache, title: "Cache · \(url.lastPathComponent)", url: url)) }
        }
        if let temporary {
            for folder in children(temporary) where folder.lastPathComponent.hasPrefix("avpplay-") {
                roots.append(Root(category: .cache, title: "Temporário da sessão · \(folder.lastPathComponent)", url: folder))
            }
        }
        // Fixed category order makes attribution deterministic. Categories are not additive physical space.
        var rootIDs: Set<String> = []
        let ordered = LocalStorageCategory.allCases.flatMap { category in roots.filter { $0.category == category } }
            .filter { rootIDs.insert($0.category.rawValue + ":" + $0.url.standardizedFileURL.path).inserted }
        let ownership = GameStorageOwnership.discover(base: base, variants: variants, recipes: recipes, roots: ordered, cache: cache)
        return scan(roots: ordered, ownership: ownership)
    }
}
