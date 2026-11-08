import XCTest
@testable import AVPPlayCore

final class GameStorageTotalsTests: XCTestCase {
    func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("game-totals-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func write(_ bytes: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes.utf8).write(to: url)
    }
    func testOneGameCombinesAllCategoriesDeduplicatingPathsAndHardLinks() throws {
        let root = try scratch()
        var owner = GameStorageOwnership(titles: ["re4": "Resident Evil 4"])
        let folders = ["store", "library", "build", "cache"]
        for name in folders { try write("data", root.appendingPathComponent(name + "/file")); owner.associate(root.appendingPathComponent(name), with: ["re4"]) }
        try FileManager.default.linkItem(at: root.appendingPathComponent("store/file"), to: root.appendingPathComponent("library/link"))
        var roots = zip(folders, LocalStorageCategory.allCases).map { name, category in LocalStorageInventory.Root(category: category, title: name, url: root.appendingPathComponent(name)) }
        roots.append(roots[0])
        let result = LocalStorageInventory.scan(roots: roots, ownership: owner)
        XCTAssertEqual(result.games, [.init(id: "re4", title: "Resident Evil 4", bytes: 16)])
        XCTAssertEqual(result.uniqueLogicalBytes, 16); XCTAssertEqual(result.unassignedBytes, 0)
    }
    func testCrossGameAndUnknownHardLinksAreNeverAssignedToFirstGame() throws {
        let root = try scratch(), first = root.appendingPathComponent("re4/file"), other = root.appendingPathComponent("batman/link")
        try write("shared", first)
        try FileManager.default.createDirectory(at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: first, to: other)
        var owner = GameStorageOwnership(titles: ["re4": "Resident Evil 4", "batman": "Batman"])
        owner.associate(first, with: ["re4"]); owner.associate(other, with: ["batman"])
        let roots = [first, other].map { LocalStorageInventory.Root(category: .library, title: "file", url: $0) }
        let a = LocalStorageInventory.scan(roots: roots, ownership: owner)
        let b = LocalStorageInventory.scan(roots: roots.reversed(), ownership: owner)
        XCTAssertEqual(a.games, b.games); XCTAssertEqual(a.games.map(\.bytes), [0, 0])
        XCTAssertTrue(a.games.allSatisfy(\.partial)); XCTAssertEqual(a.unassignedBytes, 6)
        let unknown = root.appendingPathComponent("unknown")
        try FileManager.default.linkItem(at: first, to: unknown)
        let c = LocalStorageInventory.scan(roots: [roots[0], .init(category: .cache, title: "unknown", url: unknown)], ownership: owner)
        XCTAssertEqual(c.games.first?.bytes, 0); XCTAssertEqual(c.unassignedBytes, 6)
    }
    func testMissingReferenceAndSymlinksMakeTotalPartialWithoutCountingOfflineBytes() throws {
        let root = try scratch(), live = root.appendingPathComponent("live"), missing = root.appendingPathComponent("offline/main.obb")
        try write("present", live.appendingPathComponent("file"))
        try FileManager.default.createSymbolicLink(at: live.appendingPathComponent("link"), withDestinationURL: root)
        var owner = GameStorageOwnership(titles: ["re4": "Resident Evil 4"])
        owner.associate(live, with: ["re4"]); owner.associate(missing, with: ["re4"])
        let result = LocalStorageInventory.scan(roots: [.init(category: .library, title: "live", url: live), .init(category: .library, title: "offline", url: missing)], ownership: owner)
        XCTAssertEqual(result.games.first?.bytes, 7); XCTAssertEqual(result.games.first?.partial, true)
    }
    func testDiscoveryUsesPackageReferencesAndProductMetadataNotMisleadingNames() throws {
        let root = try scratch(), recipe = try ResumeReuseTests().recipe()
        let store = ContentStore(root: root.appendingPathComponent("store"))
        try write("store", store.directory(for: recipe).appendingPathComponent("file"))
        let variants = LocalAPKVariantStore(root: root.appendingPathComponent("variants"))
        let folder = variants.root.appendingPathComponent("\(recipe.id)-\(recipe.versionCode)")
        let external = root.appendingPathComponent("external/main.obb")
        try write("obb", external)
        let variant = LocalAPKVariant(id: "fixture", recipeID: recipe.id, recipeVersionCode: recipe.versionCode,
            relativePath: "\(folder.lastPathComponent)/base.apk", size: 3, sha256: String(repeating: "a", count: 64),
            package: recipe.package, versionCode: String(recipe.versionCode), architectures: ["arm64-v8a"], source: "local",
            trustStatus: "local-unverified", official: false, recipeValidated: false,
            assets: [.init(name: "main.obb", sourcePath: external.path, size: 3, sha256: String(repeating: "b", count: 64), recipeSizeMatches: true)], registeredAt: Date())
        try write("apk", folder.appendingPathComponent("base.apk"))
        try JSONEncoder().encode(variant).write(to: folder.appendingPathComponent("fixture.json"))
        let workspace = root.appendingPathComponent("build-only/fixture-\(UUID())")
        let app = workspace.appendingPathComponent("product.app")
        try write("binary", app.appendingPathComponent("binary"))
        let info = try PropertyListSerialization.data(fromPropertyList: ["KLTree": KleptonRecipeCompatibility.resolve(recipe).toolchain.target], format: .xml, options: 0)
        try info.write(to: app.appendingPathComponent("Info.plist"))
        try write("cache", workspace.appendingPathComponent("intermediate"))
        let misleading = root.appendingPathComponent("re4-fake.app"); try write("unknown", misleading.appendingPathComponent("binary"))
        let roots: [LocalStorageInventory.Root] = [
            .init(category: .store, title: "store", url: store.directory(for: recipe)),
            .init(category: .library, title: "library", url: folder),
            .init(category: .library, title: "obb", url: external),
            .init(category: .builds, title: "product", url: app),
            .init(category: .cache, title: "workspace", url: workspace, excluding: [app]),
            .init(category: .builds, title: "misleading", url: misleading)]
        var alias = recipe; alias.id = "another-recipe-same-game"
        let ownership = GameStorageOwnership.discover(base: root, variants: variants, recipes: [recipe, alias], roots: roots, cache: root.appendingPathComponent("cache"))
        let result = LocalStorageInventory.scan(roots: roots, ownership: ownership)
        XCTAssertEqual(result.games.count, 1, "Same package must group recipe aliases")
        XCTAssertEqual(result.games[0].title, recipe.title)
        XCTAssertEqual(result.games[0].bytes, 5 + 3 + 3 + 6 + 5 + Int64(info.count) + Int64(try Data(contentsOf: folder.appendingPathComponent("fixture.json")).count))
        XCTAssertEqual(result.unassignedBytes, 7, "A suggestive app filename is not ownership evidence")
        XCTAssertFalse(result.games[0].partial)
    }
    func testGenericToolchainRemainsUnassignedWhilePreparedGameDataIsCounted() throws {
        let root = try scratch(), recipe = try ResumeReuseTests().recipe()
        let target = root.appendingPathComponent(KleptonRecipeCompatibility.resolve(recipe).toolchain.target)
        try write("stamp", target.appendingPathComponent(".qi-prepared")); try write("assets", target.appendingPathComponent("asset"))
        try write("shared-runtime", root.appendingPathComponent("runtime/file"))
        let roots: [LocalStorageInventory.Root] = [.init(category: .builds, title: "generic toolchain", url: root)]
        let owner = GameStorageOwnership.discover(base: root, variants: LocalAPKVariantStore(root: root.appendingPathComponent("variants")), recipes: [recipe], roots: roots, cache: root.appendingPathComponent("cache"))
        let result = LocalStorageInventory.scan(roots: roots, ownership: owner)
        XCTAssertEqual(result.games.first?.bytes, 11); XCTAssertEqual(result.unassignedBytes, 14)
    }
}
