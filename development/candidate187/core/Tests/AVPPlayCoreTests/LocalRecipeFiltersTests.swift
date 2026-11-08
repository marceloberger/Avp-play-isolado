import XCTest
@testable import AVPPlayCore

final class LocalRecipeFiltersTests: XCTestCase {
    func testOnlyAndHideModesCombineWithoutAService() {
        let favorites = LocalRecipeFilter(id: "favorites", name: "Favorites", recipeIDs: ["batman", "moss"])
        let unsupported = LocalRecipeFilter(id: "unsupported", name: "Unsupported", recipeIDs: ["moss"])

        XCTAssertTrue(LocalRecipeFilters.passes("batman", filters: [favorites, unsupported], modes: ["favorites": .only]))
        XCTAssertFalse(LocalRecipeFilters.passes("moss", filters: [favorites, unsupported], modes: ["favorites": .only, "unsupported": .hide]))
        XCTAssertFalse(LocalRecipeFilters.passes("alyx", filters: [favorites, unsupported], modes: ["favorites": .only]))
        XCTAssertTrue(LocalRecipeFilters.passes("alyx", filters: [favorites, unsupported], modes: [:]))
    }

    func testFilterNamesAreCleanAndUniqueIgnoringCaseAndDiacritics() {
        let filter = LocalRecipeFilter(id: "one", name: "Café")
        XCTAssertEqual(LocalRecipeFilters.cleanName("  My\n games  "), "My  games")
        XCTAssertNotNil(LocalRecipeFilters.nameProblem("café", in: [filter]))
        XCTAssertNil(LocalRecipeFilters.nameProblem("Café", in: [filter], except: "one"))
        XCTAssertNotNil(LocalRecipeFilters.nameProblem(" \n ", in: []))
        XCTAssertEqual(LocalRecipeFilters.cleanName(String(repeating: "x", count: 60)).count, 40)
    }

    func testFiltersAndModesPersistOnlyKnownIdentifiers() throws {
        let filters = [LocalRecipeFilter(id: "one", name: "VR", recipeIDs: ["batman"])]
        let decoded = LocalRecipeFilters.decode(LocalRecipeFilters.encode(filters))
        XCTAssertEqual(decoded, filters)

        let encodedModes = LocalRecipeFilters.encodeModes(["one": .only, "old": .hide, "off": .off])
        XCTAssertEqual(LocalRecipeFilters.decodeModes(encodedModes, filters: filters), ["one": .only])
        XCTAssertEqual(LocalRecipeFilters.decode(Data("bad".utf8)), [])
    }
}
