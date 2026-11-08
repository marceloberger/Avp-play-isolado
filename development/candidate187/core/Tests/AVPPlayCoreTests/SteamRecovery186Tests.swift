import XCTest
@testable import AVPPlayCore

final class SteamRecovery186Tests: XCTestCase {
    private let app = SteamAndroidApp(appId: "2059670", name: "Synthetic Steam game",
        depots: [.init(id: "2059671", manifest: "123456789", bytes: 100)], apks: ["synthetic.apk"])
    private func fixture(libraries: [String] = ["libmain.so", "libunity.so"]) throws -> (URL, URL, SteamDraftMaker) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("steam186-" + UUID().uuidString)
        let depot = root.appendingPathComponent("depot")
        try FileManager.default.createDirectory(at: depot, withIntermediateDirectories: true)
        _ = try LocalAPKVariantTests().makeAPK(in: depot, package: "com.example.steam186", versionCode: "519", nativeLibraries: libraries)
        try FileManager.default.removeItem(at: depot.appendingPathComponent("synthetic-apk"))
        try Data("synthetic obb".utf8).write(to: depot.appendingPathComponent("main.519.com.example.steam186.obb"))
        try FileManager.default.createDirectory(at: depot.appendingPathComponent("bundles"), withIntermediateDirectories: true)
        try Data("synthetic payload".utf8).write(to: depot.appendingPathComponent("bundles/payload.pak"))
        let tool = SteamTool(directory: root.appendingPathComponent("tool"), home: root.appendingPathComponent("home"))
        return (root, depot, SteamDraftMaker(tool: tool, store: ContentStore(root: root.appendingPathComponent("store")), account: "fixture"))
    }
    func testDownloadedDepotGenerates850SteamRecipeWithHashesAndAdoptsAllContent() throws {
        let (root, depot, maker) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try Hashing.sha256(of: depot.appendingPathComponent("synthetic.apk"))
        let recipe = try maker.prepareDownloaded(app: app, folders: [depot], target: DraftRecipe.genericTarget(appId:), minCommit: "cc2856c")
        XCTAssertEqual(recipe.source, .steam); XCTAssertEqual(recipe.store.steamAppId, app.appId)
        XCTAssertNil(recipe.store.appId, "A Steam ID must never become a Meta AppID")
        XCTAssertEqual(recipe.package, "com.example.steam186"); XCTAssertEqual(recipe.versionCode, 519)
        XCTAssertEqual(recipe.toolchain.minCommit, "cc2856c"); XCTAssertEqual(recipe.files.count, 3)
        XCTAssertEqual(recipe.status.playability, "untested")
        try recipe.validateForJob()
        for file in recipe.files {
            XCTAssertNotNil(file.sha256)
            XCTAssertTrue(FileManager.default.fileExists(atPath: maker.store.url(for: file, in: recipe).path))
            XCTAssertEqual(try Hashing.sha256(of: maker.store.url(for: file, in: recipe)), file.sha256)
        }
        XCTAssertEqual(try Hashing.sha256(of: depot.appendingPathComponent("synthetic.apk")), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("jobs").path))
        // Existing recipe-based fetching recognizes the recovered source; no replacement downloader.
        XCTAssertTrue(SteamFetcher.usesSteam(recipe))
        XCTAssertTrue(SteamFetcher.needed(recipe: recipe, store: maker.store).files.isEmpty)
    }
    func testUnsupportedEngineOldRuntimeAndCancelledGenerationDoNotAdoptFiles() throws {
        let (root, depot, maker) = try fixture(libraries: ["libunknown.so"])
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try maker.prepareDownloaded(app: app, folders: [depot], target: DraftRecipe.genericTarget(appId:), minCommit: "cc2856c"))
        XCTAssertThrowsError(try maker.prepareDownloaded(app: app, folders: [depot], target: DraftRecipe.genericTarget(appId:), minCommit: "a61188d"))
        XCTAssertThrowsError(try maker.prepareDownloaded(app: app, folders: [depot], target: DraftRecipe.genericTarget(appId:), minCommit: "cc2856c", shouldStop: { true }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: maker.store.root.path))
    }
    func testDuplicateDepotPathsAndWrongPackageMainOBBAreRejected() throws {
        let (root, depot, maker) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try maker.prepareDownloaded(app: app, folders: [depot, depot], target: DraftRecipe.genericTarget(appId:), minCommit: "cc2856c"))
        try Data("wrong package".utf8).write(to: depot.appendingPathComponent("main.519.com.someone.else.obb"))
        XCTAssertThrowsError(try maker.prepareDownloaded(app: app, folders: [depot], target: DraftRecipe.genericTarget(appId:), minCommit: "cc2856c"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: maker.store.root.path))
    }
}
