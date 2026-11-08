import XCTest
import SwiftUI
import AppKit
@testable import AVPPlayApp
@testable import AVPPlayCore

final class Consolidated176UITests: XCTestCase {
    @MainActor
    func testRecoveredFiltersAndHorizonReachVisibleGamesAndRenderSwiftUI() throws {
        let keys = ["customFilters", "customFilterModes", "filterHorizonGames", "filterHorizonIndie", "filterVerified", "filterCommunity", "filterInstalled", "filterDownloaded", "filterFavourites", "filterFavouritesMissing", "filterMixedReality"]
        let saved = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer { for (key, value) in saved { UserDefaults.standard.set(value, forKey: key) } }
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ui176-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = Paths(recipes: nil, store: ContentStore(root: root.appendingPathComponent("store")),
            jobs: JobStore(directory: root.appendingPathComponent("jobs")), packager: ToolchainPackager(root: root.appendingPathComponent("toolchains")))
        let model = AppModel(paths: paths, runJobsAutomatically: false)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var recipe = try RecipeStore(directory: repo.appendingPathComponent("recipes")).load(id: "store-3240283705987790")
        recipe.store.appId = "3240283705987790"
        let game = model.localGame(for: recipe)
        XCTAssertTrue(AppSection.allCases.contains(.filters))
        model.horizonPlus = HorizonPlusCatalog(checked: Date(), games: [HorizonPlusGame(appId: "3240283705987790", title: "Fixture", catalogue: .games)])
        model.filterHorizonGames = true
        XCTAssertEqual(model.visible([game]).count, 1)
        model.filterHorizonGames = false; model.filterHorizonIndie = true
        XCTAssertTrue(model.visible([game]).isEmpty)
        model.filterHorizonIndie = false
        let filter = try XCTUnwrap(model.createFilter(named: "Fixture", games: [game.id]))
        model.setFilterMode(filter.id, .hide)
        XCTAssertTrue(model.visible([game]).isEmpty)
        model.setFilterMode(filter.id, .only)
        XCTAssertEqual(model.visible([game]).count, 1)
        let view = NSHostingView(rootView: FiltersView().environmentObject(model))
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(view.fittingSize.height, 0)
    }
}
