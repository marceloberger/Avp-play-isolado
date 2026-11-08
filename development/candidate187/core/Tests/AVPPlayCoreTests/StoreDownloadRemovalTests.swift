import XCTest
@testable import AVPPlayCore

final class StoreDownloadRemovalTests: XCTestCase {
    func fixture() throws -> (URL, ContentStore, Recipe, LocalAPKVariantStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("removal-fixture-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        var recipe = try ResumeReuseTests().recipe()
        recipe.files = [
            RecipeFile(name: "base.apk", role: "apk", id: "apk", required: true),
            RecipeFile(name: "main.obb", role: "obb", id: "obb", required: true),
            RecipeFile(name: "receipt.json", role: "data", id: "r", required: false)]
        let store = ContentStore(root: root.appendingPathComponent("store"))
        try FileManager.default.createDirectory(at: store.directory(for: recipe), withIntermediateDirectories: true)
        return (root, store, recipe, LocalAPKVariantStore(root: root.appendingPathComponent("variants")))
    }
    func testOnlyReviewedDownloadIsRemovedAndEverythingElseSurvives() throws {
        let (root, store, recipe, variants) = try fixture(), folder = store.directory(for: recipe)
        let protected = [folder.appendingPathComponent("base.apk"), folder.appendingPathComponent("receipt.json"),
            folder.appendingPathComponent("backup.app/file"), root.appendingPathComponent("jobs/job.json"),
            root.appendingPathComponent("backups/file"), root.appendingPathComponent("build-only/app/file")]
        for url in protected + [folder.appendingPathComponent("main.obb")] { try LocalStorageInventoryTests().write("data", url) }
        let plan = try StoreDownloadRemoval(store: store, recipe: recipe, variants: variants)
        XCTAssertEqual(plan.files.map(\.lastPathComponent), ["main.obb"])
        XCTAssertThrowsError(try plan.remove(approved: false))
        try plan.remove(approved: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("main.obb").path))
        for url in protected { XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.path) }
    }
    func testStalePlanAndSymlinksAreRejected() throws {
        let (root, store, recipe, variants) = try fixture(), folder = store.directory(for: recipe)
        let obb = folder.appendingPathComponent("main.obb")
        try LocalStorageInventoryTests().write("original", obb)
        let plan = try StoreDownloadRemoval(store: store, recipe: recipe, variants: variants)
        try Data("modified".utf8).write(to: obb)
        XCTAssertThrowsError(try plan.remove(approved: true)); XCTAssertTrue(FileManager.default.fileExists(atPath: obb.path))
        try FileManager.default.moveItem(at: folder, to: root.appendingPathComponent("moved"))
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: root.appendingPathComponent("moved"))
        XCTAssertThrowsError(try StoreDownloadRemoval(store: store, recipe: recipe, variants: variants))
        XCTAssertThrowsError(try plan.remove(approved: true))
    }
    func testVariantReferencesAddedAfterReviewPreventDeletion() throws {
        let (_, store, recipe, variants) = try fixture(), obb = store.directory(for: recipe).appendingPathComponent("main.obb")
        try LocalStorageInventoryTests().write("data", obb)
        let plan = try StoreDownloadRemoval(store: store, recipe: recipe, variants: variants)
        let variant = LocalAPKVariant(id: "fixture", recipeID: recipe.id, recipeVersionCode: recipe.versionCode,
            relativePath: "fixture.apk", size: 3, sha256: String(repeating: "a", count: 64), package: recipe.package,
            versionCode: String(recipe.versionCode), architectures: ["arm64-v8a"], source: "local", trustStatus: "local-unverified",
            official: false, recipeValidated: false, assets: [.init(name: "main.obb", sourcePath: obb.path,
                size: 4, sha256: String(repeating: "b", count: 64), recipeSizeMatches: true)], registeredAt: Date())
        let metadata = variants.root.appendingPathComponent("variant/fixture.json")
        try FileManager.default.createDirectory(at: metadata.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(variant).write(to: metadata)
        XCTAssertThrowsError(try plan.remove(approved: true))
        XCTAssertTrue(try StoreDownloadRemoval(store: store, recipe: recipe, variants: variants).files.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: obb.path))
        try Data("invalid".utf8).write(to: metadata)
        XCTAssertThrowsError(try StoreDownloadRemoval(store: store, recipe: recipe, variants: variants))
    }
}
