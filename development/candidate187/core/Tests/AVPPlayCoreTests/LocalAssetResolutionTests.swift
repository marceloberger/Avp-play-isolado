import XCTest
@testable import AVPPlayCore

/// Tiny synthetic assets in disposable folders; never reads personal game content.
final class LocalAssetResolutionTests: XCTestCase {
    func fixture(size: Int64? = nil, hash: String? = nil) throws -> (URL, Recipe) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("asset-resolution-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let recipes = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("recipes")
        var recipe = try RecipeStore(directory: recipes).load(id: "batman")
        recipe.files = [.init(name: "main.obb", role: "obb", id: "fixture", size: size, sha256: hash, required: true)]
        return (root.resolvingSymlinksInPath(), recipe)
    }
    func put(_ bytes: String, in root: URL, folder: String) throws -> URL {
        let dir = root.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("main.obb")
        try Data(bytes.utf8).write(to: file)
        return file
    }
    func testUnknownDuplicateAssetsAreRejectedInsteadOfPickingFirst() throws {
        let (root, recipe) = try fixture()
        _ = try put("first", in: root, folder: "a")
        _ = try put("second", in: root, folder: "z")
        XCTAssertThrowsError(try LocalGameImport().discover(in: root, recipe: recipe)) {
            XCTAssertTrue(String(describing: $0).contains("main.obb"))
        }
    }
    func testAuthoritativeSizeResolvesOneCandidate() throws {
        let (root, recipe) = try fixture(size: 4)
        _ = try put("wrong length", in: root, folder: "a")
        let correct = try put("good", in: root, folder: "z")
        let found = try LocalGameImport().discover(in: root, recipe: recipe)
        XCTAssertEqual(found.files["main.obb"]?.resolvingSymlinksInPath().path, correct.resolvingSymlinksInPath().path)
        XCTAssertFalse(found.canInstall, "Asset selection alone cannot establish a compatible APK")
    }
    func testHashResolvesSameSizeCandidatesWithoutChangingSource() throws {
        let (root, recipe) = try fixture(size: 4, hash: Hashing.sha256(of: Data("good".utf8)))
        let wrong = try put("evil", in: root, folder: "a")
        let correct = try put("good", in: root, folder: "z")
        let before = try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted()
        let found = try LocalGameImport().discover(in: root, recipe: recipe)
        XCTAssertEqual(found.files["main.obb"]?.resolvingSymlinksInPath().path, correct.resolvingSymlinksInPath().path)
        XCTAssertEqual(try Data(contentsOf: wrong), Data("evil".utf8))
        XCTAssertEqual(try Data(contentsOf: correct), Data("good".utf8))
        XCTAssertEqual(try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted(), before)
    }
    func testIdenticalCopiesStillRequireAnUnambiguousSource() throws {
        let (root, recipe) = try fixture(size: 4, hash: Hashing.sha256(of: Data("good".utf8)))
        _ = try put("good", in: root, folder: "a")
        _ = try put("good", in: root, folder: "z")
        XCTAssertThrowsError(try LocalGameImport().discover(in: root, recipe: recipe))
    }
    func testNoMatchingDuplicateIsRejected() throws {
        let (root, recipe) = try fixture(size: 100)
        _ = try put("bad", in: root, folder: "a")
        _ = try put("also bad", in: root, folder: "z")
        XCTAssertThrowsError(try LocalGameImport().discover(in: root, recipe: recipe))
    }
    func testOverlappingSearchRootsDoNotCreateFalseAmbiguity() throws {
        let (root, recipe) = try fixture()
        let asset = try put("unique", in: root, folder: "assets")
        let found = try LocalGameImport().discover(in: root, recipe: recipe, additionalSources: [root, asset.deletingLastPathComponent()])
        XCTAssertEqual(found.files["main.obb"]?.resolvingSymlinksInPath().path, asset.resolvingSymlinksInPath().path)
    }
}
