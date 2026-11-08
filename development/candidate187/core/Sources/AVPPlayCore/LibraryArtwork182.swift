import Foundation

/// New artwork cache only. Existing game data/covers are read, never rewritten.
public struct LibraryArtwork182: Sendable {
    public struct Origin: Codable, Sendable {
        public var source: String
        public var page: String?
        public var image: String
        public var sha256: String
        public var cachedAt: Date
    }
    public struct Artwork: Sendable {
        public var data: Data
        public var origin: Origin
    }
    public let directory: URL
    public init(directory: URL = DataLocation.base.appendingPathComponent("cache/library182", isDirectory: true)) {
        self.directory = directory
    }
    public func cached(appID: String) -> Artwork? {
        guard CoverCache.isAppId(appID), let data = CoverCache(directory: directory).cached(appId: appID),
              let meta = try? Data(contentsOf: directory.appendingPathComponent(appID + ".origin.json")),
              let origin = try? JSONDecoder().decode(Origin.self, from: meta),
              origin.sha256 == Hashing.sha256(of: data) else { return nil }
        return Artwork(data: data, origin: origin)
    }
    public func existing(appID: String?, paths: [URL]) -> Artwork? {
        if let appID, let saved = cached(appID: appID) { return saved }
        for path in paths {
            if let data = try? Data(contentsOf: path), !data.isEmpty {
                return Artwork(data: data, origin: Origin(source: "Cache local existente; origem editorial não registrada",
                    page: nil, image: path.absoluteString, sha256: Hashing.sha256(of: data), cachedAt: Date()))
            }
        }
        return nil
    }
    public func fetchOfficial(appID: String) async -> Artwork? {
        guard CoverCache.isAppId(appID) else { return nil }
        if let saved = cached(appID: appID) { return saved }
        let cache = CoverCache(directory: directory)
        guard !cache.isKnownMissing(appId: appID) else { return nil }
        guard let source = await StoreArt().squareCoverWithOrigin(appId: appID),
              let image = cache.store(appId: appID, original: source.data) else {
            cache.noteMissing(appId: appID); return nil
        }
        let origin = Origin(source: "Meta Store · imagem oficial", page: source.page.absoluteString,
                            image: source.image.absoluteString, sha256: Hashing.sha256(of: image), cachedAt: Date())
        guard let metadata = try? JSONEncoder().encode(origin) else { return nil }
        do { try metadata.write(to: directory.appendingPathComponent(appID + ".origin.json"), options: .atomic) }
        catch { return nil }
        return Artwork(data: image, origin: origin)
    }
}
