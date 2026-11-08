import XCTest
@testable import AVPPlayApp
@testable import AVPPlayCore

final class Build157PresentationTests: XCTestCase {
    func testExperimentalPrimaryRecipeIsNeverLabelledVerifiedByCatalog() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("avp157-presentation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let recipe = try RecipeStore(directory: repo.appendingPathComponent("recipes")).load(id: "local-7527722310622065")
        let paths = Paths(recipes: nil, store: ContentStore(root: root.appendingPathComponent("store")),
            jobs: JobStore(directory: root.appendingPathComponent("jobs")),
            packager: ToolchainPackager(root: root.appendingPathComponent("toolchains")))
        var game = Probe.game(recipe, draft: false, tested: recipe, variants: [], sources: [],
            paths: paths, apps: nil, toolchainRevision: nil, bundlePrefix: "test.isolated")
        XCTAssertEqual(game.verifiedVersions.first?.kind, .store)
        let data = Data(#"{"appId":"7527722310622065","title":"Cave Crave","package":"com.rrrgames.CaveCrave","status":"verified","works":0,"problems":0,"fails":0}"#.utf8)
        game.catalog = try JSONDecoder().decode(CatalogGame.self, from: data)
        XCTAssertEqual(game.trust, .untested)
        game.catalog?.status = "incompatible"
        XCTAssertEqual(game.trust, .incompatible)
    }
}
