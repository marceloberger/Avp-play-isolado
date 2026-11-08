import Foundation

/// Logical file totals, not allocated disk blocks or reclaimable space.
public struct GameStorageTotal: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var title: String
    public var bytes: Int64 = 0
    public var partial: Bool = false
}

/// Read-only provenance for reporting. Never authorizes installation, reuse or integrity exceptions.
struct GameStorageOwnership {
    var titles: [String: String] = [:]
    var paths: [String: Set<String>] = [:]

    static func path(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }
    mutating func associate(_ url: URL, with owners: Set<String>) {
        guard !owners.isEmpty else { return }
        paths[Self.path(url), default: []].formUnion(owners)
    }
    func owners(of url: URL) -> Set<String> {
        var path = Self.path(url), result: Set<String> = []
        while path != "/" && !path.isEmpty {
            result.formUnion(paths[path] ?? [])
            path = (path as NSString).deletingLastPathComponent
        }
        return result
    }

    static func discover(base: URL, variants: LocalAPKVariantStore, recipes: [Recipe],
                         roots: [LocalStorageInventory.Root], cache: URL) -> Self {
        var result = Self()
        let fm = FileManager.default
        func children(_ url: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true }
                .sorted { $0.path < $1.path }
        }
        func gameID(_ recipe: Recipe) -> String { recipe.package.isEmpty ? "recipe:" + recipe.id : "package:" + recipe.package }
        let ordered = recipes.sorted { ($0.id.hasPrefix("store-") ? 1 : 0, $0.id) < ($1.id.hasPrefix("store-") ? 1 : 0, $1.id) }
        var recipeOwners: [String: Set<String>] = [:], targets: [String: Set<String>] = [:]
        for recipe in ordered {
            let id = gameID(recipe)
            if result.titles[id] == nil { result.titles[id] = recipe.title }
            recipeOwners[recipe.id, default: []].insert(id)
            for target in [recipe.toolchain.target, KleptonRecipeCompatibility.resolve(recipe).toolchain.target] {
                targets[target, default: []].insert(id)
            }
            if let appID = recipe.catalogAppId {
                for ext in ["jpg", "none"] { result.associate(cache.appendingPathComponent("covers/\(appID).\(ext)"), with: [id]) }
            }
        }
        func folderOwners(_ name: String) -> Set<String> {
            ordered.reduce(into: Set<String>()) { ids, recipe in
                let prefix = recipe.id + "-"
                if name.hasPrefix(prefix), Int(name.dropFirst(prefix.count)) != nil { ids.insert(gameID(recipe)) }
            }
        }
        for root in roots where root.category == .store {
            result.associate(root.url, with: folderOwners(root.url.lastPathComponent))
        }
        for folder in children(variants.root) where !folder.lastPathComponent.hasPrefix(".") && folder.lastPathComponent != "learned-recipes" {
            result.associate(folder, with: folderOwners(folder.lastPathComponent))
            for file in children(folder) where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file), let variant = try? JSONDecoder().decode(LocalAPKVariant.self, from: data) else { continue }
                let ids = recipeOwners[variant.recipeID] ?? []
                result.associate(folder, with: ids)
                result.associate(variants.root.appendingPathComponent(variant.relativePath), with: ids)
                // Only explicit references, never same-size APK guesses or whole external source folders.
                for asset in variant.assets ?? [] { result.associate(URL(fileURLWithPath: asset.sourcePath), with: ids) }
                if let source = variant.originalAPKSourcePath { result.associate(URL(fileURLWithPath: source), with: ids) }
            }
        }
        for file in children(variants.root.appendingPathComponent("learned-recipes")) where file.pathExtension == "json" {
            result.associate(file, with: folderOwners(file.deletingPathExtension().lastPathComponent))
        }
        for file in children(base.appendingPathComponent("jobs")) where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file), let job = try? JSONDecoder().decode(Job.self, from: data) else { continue }
            let id = gameID(job.recipe)
            result.titles[id] = result.titles[id] ?? job.recipe.title
            result.associate(file, with: [id])
            result.associate(file.deletingPathExtension().appendingPathExtension("log"), with: [id])
        }
        func productOwners(_ app: URL) -> Set<String> {
            guard let data = (try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")))
                    ?? (try? Data(contentsOf: app.appendingPathComponent("Info.plist"))),
                  let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let target = info["KLTree"] as? String else { return [] }
            return targets[target] ?? []
        }
        // Find exact product/target markers, including inside toolchains. No attribution from a filename alone.
        var inspected: Set<String> = []
        for root in roots where root.category == .builds || root.category == .cache || root.category == .library {
            guard inspected.insert(Self.path(root.url)).inserted else { continue }
            var evidence: [(URL, Set<String>)] = []
            if root.url.pathExtension == "app" { evidence.append((root.url, productOwners(root.url))) }
            else if let walker = fm.enumerator(at: root.url, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
                for case let file as URL in walker {
                    if (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { walker.skipDescendants(); continue }
                    if file.pathExtension == "app" { evidence.append((file, productOwners(file))); walker.skipDescendants() }
                    if file.lastPathComponent == ".qi-prepared" {
                        let folder = file.deletingLastPathComponent()
                        evidence.append((folder, targets[folder.lastPathComponent] ?? []))
                    }
                }
            }
            for (url, owners) in evidence { result.associate(url, with: owners) }
            // Workspace source/intermediate files belong to a game only with a product/prepared marker.
            if root.category == .cache, ["build-only", "compiled-games"].contains(root.url.deletingLastPathComponent().lastPathComponent) {
                let owners = evidence.reduce(into: Set<String>()) { $0.formUnion($1.1) }
                result.associate(root.url, with: owners)
            }
        }
        // Hash-cache records explicitly identify their source path. Global cache/log files stay unassigned.
        for directory in [base.appendingPathComponent(".sha256-cache"), variants.root.appendingPathComponent(".sha256-cache")] {
            for file in children(directory) where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file), let entry = try? JSONDecoder().decode(SHA256FileCache.Entry.self, from: data) else { continue }
                result.associate(file, with: result.owners(of: URL(fileURLWithPath: entry.identity.path)))
            }
        }
        return result
    }
}
