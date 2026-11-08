import XCTest
import SwiftUI
import AppKit
@testable import AVPPlayApp
@testable import AVPPlayCore

final class SteamDiscovery186Tests: XCTestCase {
    private let app = SteamAndroidApp(appId: "2059670", name: "Synthetic Steam game",
        depots: [.init(id: "2059671", manifest: "123456789", bytes: 20)], apks: ["synthetic.apk"])
    @MainActor private func model() throws -> (AppModel, URL) {
        guard let path = ProcessInfo.processInfo.environment["AVPPLAY_HOME"],
              URL(fileURLWithPath: path).resolvingSymlinksInPath().path.hasPrefix(URL(fileURLWithPath: "/private/tmp").resolvingSymlinksInPath().path + "/") else {
            throw XCTSkip("Disposable AVPPLAY_HOME is required")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("steam-ui186-" + UUID().uuidString)
        let paths = Paths(recipes: nil, store: ContentStore(root: root.appendingPathComponent("store")),
            jobs: JobStore(directory: root.appendingPathComponent("jobs")), packager: ToolchainPackager(root: root.appendingPathComponent("toolchains")))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (AppModel(paths: paths, runJobsAutomatically: false, resumeDevices: { [] }), root)
    }
    @MainActor func testDiscoveredLibraryPublishesSteamPlaceholderAndResetRemovesIt() throws {
        let (model, _) = try model()
        model.steamLibraryAccount = model.steamAccount
        model.steamLibrary = .init(checked: Date(), apps: [app, app])
        XCTAssertEqual(model.allGames.count, 1)
        let game = try XCTUnwrap(model.allGames.first)
        XCTAssertEqual(game.recipe.store.steamAppId, app.appId)
        XCTAssertNil(game.recipe.store.appId)
        XCTAssertTrue(game.draft); XCTAssertFalse(game.prepared)
        XCTAssertNotNil(model.steamDraftApp(game))
        XCTAssertEqual(model.owned(game), .yes)
        model.resetSteamLibrary()
        XCTAssertTrue(model.allGames.isEmpty)
        XCTAssertNil(model.steamDraftApp(game))
    }
    @MainActor func testPreparedRecipeReplacesPlaceholderPersistsAndNeverQueuesJob() throws {
        let (model, root) = try model()
        model.steamLibraryAccount = model.steamAccount
        model.steamLibrary = .init(checked: Date(), apps: [app])
        let bytes = Data("synthetic apk fixture".utf8)
        let recipe = try SteamDraft.make(app: app, files: [.init(path: "synthetic.apk", size: Int64(bytes.count))],
            package: "com.example.steam186", versionCode: 519, versionName: "1", target: "x2059670", minCommit: "cc2856c") { _ in Hashing.sha256(of: bytes) }
        try FileManager.default.createDirectory(at: model.paths.store.directory(for: recipe), withIntermediateDirectories: true)
        try bytes.write(to: model.paths.store.url(for: recipe.files[0], in: recipe))
        let saved = model.draftsDirectory.appendingPathComponent(recipe.id + ".json")
        defer { try? FileManager.default.removeItem(at: saved) }
        try model.acceptSteamRecipe(recipe, app: app)
        XCTAssertEqual(model.allGames.count, 1)
        XCTAssertTrue(try XCTUnwrap(model.allGames.first).prepared)
        XCTAssertEqual(try RecipeStore(directory: model.draftsDirectory).load(id: recipe.id).store.steamAppId, app.appId)
        XCTAssertTrue(model.paths.jobs.all().isEmpty)
        XCTAssertNil(model.runningJob)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("toolchains").path))
        var invalid = recipe; invalid.store.appId = "123456789"
        XCTAssertThrowsError(try model.acceptSteamRecipe(invalid, app: app))
    }
    @MainActor func testDiscoveryControlsRenderAndExistingRecipeIsNotDuplicated() throws {
        let (model, _) = try model()
        model.steamLibraryAccount = model.steamAccount
        let recipe = SteamDraft.placeholder(app: app)
        let game = Game(recipe: recipe, status: GameStatus.of(recipe: recipe, store: model.paths.store, apps: [], toolchainVersion: nil), cover: nil, draft: true)
        model.games = [game]
        model.steamLibrary = .init(checked: Date(), apps: [app])
        XCTAssertEqual(model.allGames.count, 1)
        let host = NSHostingView(rootView: SteamDiscoveryControls().environmentObject(model))
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 100)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 0)
        XCTAssertTrue(model.paths.jobs.all().isEmpty)
    }
}
