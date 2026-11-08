import Foundation

/// A narrow, reviewable deletion: only named non-APK recipe files directly in this store folder.
/// Unknown files, subdirectories, APKs, receipts, Jobs, local variants, app bundles and backups are protected.
public struct StoreDownloadRemoval: Sendable {
    struct Item: Sendable { var url: URL; var identity: SHA256FileCache.Identity }
    public let directory: URL
    public let files: [URL]
    public let bytes: Int64
    public let preservedFiles: Int
    private let items: [Item]
    private let canonicalDirectory: URL
    private let variants: LocalAPKVariantStore

    private static func protectedPaths(_ variants: LocalAPKVariantStore) throws -> Set<String> {
        let fm = FileManager.default
        guard fm.fileExists(atPath: variants.root.path) else { return [] }
        var paths: Set<String> = []
        for folder in try fm.contentsOfDirectory(at: variants.root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            guard !folder.lastPathComponent.hasPrefix("."), folder.lastPathComponent != "learned-recipes" else { continue }
            let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw LocalAPKVariantError.unsafePath(folder.path) }
            guard values.isDirectory == true else { continue }
            for file in try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
                // An unreadable record means we cannot safely determine its dependencies.
                let variant = try JSONDecoder().decode(LocalAPKVariant.self, from: Data(contentsOf: file))
                for path in (variant.assets ?? []).map(\.sourcePath) + [variant.originalAPKSourcePath].compactMap({ $0 }) {
                    paths.insert(URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path)
                }
            }
        }
        return paths
    }

    public init(store: ContentStore, recipe: Recipe, variants: LocalAPKVariantStore = LocalAPKVariantStore()) throws {
        let protected = try Self.protectedPaths(variants)
        let directory = store.directory(for: recipe)
        let canonical = directory.resolvingSymlinksInPath().standardizedFileURL
        guard canonical.deletingLastPathComponent() == store.root.resolvingSymlinksInPath().standardizedFileURL,
              canonical == directory.standardizedFileURL else {
            throw LocalAPKVariantError.unsafePath(directory.path)
        }
        // Refuse even a directory symlink that still points inside the store.
        guard (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw LocalAPKVariantError.unsafePath(directory.path)
        }
        var selected: [Item] = []
        for file in recipe.files where file.source?.kind != .user && file.role != "apk" && file.name.lowercased().hasSuffix(".apk") == false {
            guard Recipe.isSafeName(file.name), !file.name.hasPrefix("."), file.name != "Info.plist",
                  !["json", "mobileprovision", "provisionprofile"].contains(URL(fileURLWithPath: file.name).pathExtension.lowercased()) else { continue }
            let url = directory.appendingPathComponent(file.name)
            guard !protected.contains(url.resolvingSymlinksInPath().standardizedFileURL.path),
                  (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                  let identity = try? SHA256FileCache.identity(url) else { continue }
            selected.append(Item(url: url, identity: identity))
        }
        let unique = Dictionary(grouping: selected, by: { $0.url.path }).values.compactMap(\.first).sorted { $0.url.path < $1.url.path }
        self.variants = variants
        self.directory = directory; self.canonicalDirectory = canonical
        self.items = unique; self.files = unique.map(\.url); self.bytes = unique.reduce(0) { $0 + $1.identity.size }
        self.preservedFiles = max(0, StoreMove.measure(directory).files - unique.count)
    }
    public func remove(approved: Bool) throws {
        guard approved else { throw CancellationError() }
        guard directory.resolvingSymlinksInPath().standardizedFileURL == canonicalDirectory,
              (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw LocalAPKVariantError.unsafePath(directory.path)
        }
        let protected = try Self.protectedPaths(variants)
        // Recheck the whole plan before deleting anything; a stale confirmation must not select new files.
        for item in items {
            guard !protected.contains(item.url.resolvingSymlinksInPath().standardizedFileURL.path),
                  (try? item.url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                  try SHA256FileCache.identity(item.url) == item.identity else {
                throw LocalAPKVariantError.invalidRecord("Os arquivos mudaram. Revise novamente o plano de exclusão.")
            }
        }
        for item in items { try FileManager.default.removeItem(at: item.url) }
    }
}
