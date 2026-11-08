import XCTest
@testable import AVPPlayApp
@testable import AVPPlayCore

final class FeatureNavigationTests: XCTestCase {
    @MainActor
    func testLocalBuildRecoveryDiagnosticsAreNotTruncatedInStatusText() {
        let details = String(repeating: "/workspace/check-failed/path/", count: 20)
        let error = LocalBuildRecoveryFailure(details)
        XCTAssertEqual(AppModel.shortLocalError(error), details)
    }

    func testAppleMusicAndRemoteHaveFirstClassNavigationEntries() {
        XCTAssertTrue(AppSection.allCases.contains(.appleMusic))
        XCTAssertTrue(AppSection.allCases.contains(.remote))
        XCTAssertEqual(AppSection.appleMusic.title, "Apple Music Search")
        XCTAssertEqual(AppSection.remote.title, "Remote Control")
        XCTAssertNotEqual(AppSection.appleMusic.symbol, AppSection.remote.symbol)
    }

    func testGamesCatalogueAndLocalImporterHaveSeparateNavigationEntries() {
        XCTAssertTrue(AppSection.allCases.contains(.games))
        XCTAssertTrue(AppSection.allCases.contains(.localLibrary))
        XCTAssertEqual(AppSection.games.title, "Games")
        XCTAssertEqual(AppSection.localLibrary.title, "Local Library")
        XCTAssertNotEqual(AppSection.games.symbol, AppSection.localLibrary.symbol)
    }

    @MainActor
    func testUnverifiedShippedRecipesRemainVisibleWhenTrustFiltersAreOff() throws {
        let recipesDirectory = try XCTUnwrap(Bundle.module.resourceURL).appendingPathComponent("recipes")
        let recipes = try RecipeStore(directory: recipesDirectory).loadAll()
        let unverifiedRecipe = try XCTUnwrap(recipes.first { $0.status.playability == "untested" })
        let verifiedRecipe = try XCTUnwrap(recipes.first { $0.status.playability == "verified" })
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("avp-catalog-filter-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let filterKeys = ["filterVerified", "filterCommunity", "filterInstalled", "filterDownloaded",
                          "filterFavourites", "filterFavouritesMissing", "filterMixedReality"]
        let saved = Dictionary(uniqueKeysWithValues: filterKeys.map { ($0, UserDefaults.standard.object(forKey: $0)) })
        let savedCatalog = UserDefaults.standard.object(forKey: "onlineCatalog")
        defer {
            for (key, value) in saved {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
            if let savedCatalog { UserDefaults.standard.set(savedCatalog, forKey: "onlineCatalog") }
            else { UserDefaults.standard.removeObject(forKey: "onlineCatalog") }
        }
        for key in filterKeys { UserDefaults.standard.set(false, forKey: key) }
        UserDefaults.standard.removeObject(forKey: "onlineCatalog")

        let paths = Paths(recipes: recipesDirectory,
                          store: ContentStore(root: scratch.appendingPathComponent("store")),
                          jobs: JobStore(directory: scratch.appendingPathComponent("jobs")),
                          packager: ToolchainPackager(root: scratch.appendingPathComponent("toolchains")))
        let model = AppModel(paths: paths, runJobsAutomatically: false)
        XCTAssertTrue(model.onlineCatalog, "A fresh Isolated install should match the original's default catalogue setting")
        let unverified = Game(recipe: unverifiedRecipe,
                              status: GameStatus.of(recipe: unverifiedRecipe, store: paths.store, apps: nil, toolchainVersion: nil))
        let verified = Game(recipe: verifiedRecipe,
                            status: GameStatus.of(recipe: verifiedRecipe, store: paths.store, apps: nil, toolchainVersion: nil))

        XCTAssertEqual(unverified.trust, .untested)
        XCTAssertEqual(verified.trust, .verified)
        XCTAssertEqual(model.visible([unverified, verified]).count, 2,
                       "Turning off trust filters must include untested and verified games")

        model.filterVerified = true
        let verifiedOnly = model.visible([unverified, verified])
        XCTAssertEqual(verifiedOnly.map(\.id), [verified.id])
    }

    @MainActor
    func testAppleMusicEntryOpensBeatSaberAndTogglesTheExistingPerGameBuildOption() throws {
        let recipesDirectory = try XCTUnwrap(Bundle.module.resourceURL).appendingPathComponent("recipes")
        let recipes = try RecipeStore(directory: recipesDirectory).loadAll()
        var recipe = try XCTUnwrap(recipes.first { $0.toolchain.target == "beatsaber140" })
        recipe.id += "-navigation-test-\(UUID().uuidString)"
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("avp-feature-nav-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let oldOptions = UserDefaults.standard.data(forKey: "gameOptions")
        defer {
            if let oldOptions { UserDefaults.standard.set(oldOptions, forKey: "gameOptions") }
            else { UserDefaults.standard.removeObject(forKey: "gameOptions") }
        }
        let paths = Paths(recipes: recipesDirectory,
                          store: ContentStore(root: scratch.appendingPathComponent("store")),
                          jobs: JobStore(directory: scratch.appendingPathComponent("jobs")),
                          packager: ToolchainPackager(root: scratch.appendingPathComponent("toolchains")))
        let model = AppModel(paths: paths, runJobsAutomatically: false)
        let game = model.localGame(for: recipe)

        model.section = .appleMusic
        model.openAppleMusicSearchOptions(for: game)
        XCTAssertEqual(model.section, .games)
        XCTAssertEqual(model.gamePath, [game.id])

        model.setAppleMusicSearchEnabled(true, for: game)
        XCTAssertTrue(model.options(for: game).coreMods == true)
        model.setAppleMusicSearchEnabled(false, for: game)
        XCTAssertFalse(model.options(for: game).coreMods == true)
        XCTAssertTrue(model.jobs.isEmpty, "Changing the option must not enqueue a Build")
    }
}
