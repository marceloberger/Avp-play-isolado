import XCTest
@testable import AVPPlayCore

final class LocalStorageInventoryTests: XCTestCase {
    func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("storage-fixture-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    func testOverlappingPathsHardLinksAndHiddenFilesCountOnceWithoutFollowingSymlinks() throws {
        let root = try scratch(), data = root.appendingPathComponent("library")
        let apk = data.appendingPathComponent("base.apk"), hidden = data.appendingPathComponent(".receipt")
        try write("12345", apk); try write("abc", hidden)
        try FileManager.default.linkItem(at: apk, to: data.appendingPathComponent("linked.apk"))
        try FileManager.default.createSymbolicLink(at: data.appendingPathComponent("cycle"), withDestinationURL: root)
        let result = LocalStorageInventory.scan(roots: [
            .init(category: .library, title: "library", url: data),
            .init(category: .builds, title: "overlap", url: apk),
            .init(category: .cache, title: "offline", url: root.appendingPathComponent("missing"))])
        XCTAssertEqual(result.uniqueLogicalBytes, 8)
        XCTAssertEqual(result.entries[0].referencedBytes, 13)
        XCTAssertEqual(result.entries[1].uniqueBytes, 0)
        XCTAssertFalse(result.entries[2].available)
    }
    func testCopyWithDifferentBytesIsNotDeduplicatedAndExclusionsDoNotHideOtherFiles() throws {
        let root = try scratch(), app = root.appendingPathComponent("product.app")
        try write("AAAA", app.appendingPathComponent("binary"))
        try FileManager.default.copyItem(at: app, to: root.appendingPathComponent("signed.app"))
        try write("BBBB", root.appendingPathComponent("signed.app/binary"))
        try write("src", root.appendingPathComponent("source"))
        let result = LocalStorageInventory.scan(roots: [
            .init(category: .builds, title: "app", url: app),
            .init(category: .cache, title: "remainder", url: root, excluding: [app])])
        XCTAssertEqual(result.uniqueLogicalBytes, 11)
        XCTAssertEqual(result.entries[1].referencedBytes, 7)
    }
    func testLibraryWithoutCatalogRecipeAndExternalOBBAreVisibleWhenStoreIsEmpty() throws {
        let root = try scratch(), recipe = try ResumeReuseTests().recipe()
        let variants = LocalAPKVariantStore(root: root.appendingPathComponent("local-variants"))
        let folder = variants.root.appendingPathComponent("orphan-1")
        try write("APK", folder.appendingPathComponent("base.apk"))
        let obb = root.appendingPathComponent("external/main.obb"); try write("1234567", obb)
        var variant = LocalAPKVariant(id: "fixture", recipeID: recipe.id, recipeVersionCode: recipe.versionCode,
            relativePath: "orphan-1/base.apk", size: 3, sha256: String(repeating: "a", count: 64),
            package: recipe.package, versionCode: String(recipe.versionCode), architectures: ["arm64-v8a"],
            source: "local", trustStatus: "local-unverified", official: false, recipeValidated: false, registeredAt: Date())
        variant.assets = [.init(name: "main.obb", sourcePath: obb.path, sourceRootPath: obb.deletingLastPathComponent().path,
            size: 7, sha256: String(repeating: "b", count: 64), recipeSizeMatches: true)]
        let known = variants.root.appendingPathComponent("\(recipe.id)-\(recipe.versionCode)")
        try FileManager.default.createDirectory(at: known, withIntermediateDirectories: true)
        try JSONEncoder().encode(variant).write(to: known.appendingPathComponent("fixture.json"))
        let result = LocalStorageInventory.scan(base: root, store: ContentStore(root: root.appendingPathComponent("store")),
            variants: variants, recipes: [recipe], cache: root.appendingPathComponent("cache"))
        XCTAssertTrue(result.entries.contains { $0.url.standardizedFileURL.path == folder.standardizedFileURL.path && $0.referencedBytes == 3 })
        XCTAssertTrue(result.entries.contains { $0.url == obb && $0.referencedBytes == 7 })
        XCTAssertEqual(result.entries.filter { $0.category == .store }.count, 0)
        XCTAssertGreaterThan(result.uniqueLogicalBytes, 10)
    }
    func testReadOnlyRealInventoryWhenReportRequested() throws {
        guard let report = ProcessInfo.processInfo.environment["AVPPLAY_STORAGE_INVENTORY_REPORT"] else { return }
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AVPPlayModificado")
        let recipesURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("recipes")
        let recipes = try FileManager.default.contentsOfDirectory(at: recipesURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { try JSONDecoder().decode(Recipe.self, from: Data(contentsOf: $0)) }
        let result = LocalStorageInventory.scan(base: base, store: ContentStore(root: StoreLocation.current(base: base)),
            variants: LocalAPKVariantStore(root: base.appendingPathComponent("local-variants")), recipes: recipes,
            cache: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/AVPPlayModificado"))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result).write(to: URL(fileURLWithPath: report))
        XCTAssertTrue(result.entries.contains { $0.category == .library && $0.title.contains("Resident Evil") && $0.referencedBytes > 0 })
    }

}
