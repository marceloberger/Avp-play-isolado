import XCTest
@testable import AVPPlayApp
@testable import AVPPlayCore

final class Selective180PresentationTests: XCTestCase {
    func testOptional1453IsNotPresentedAsVerifiedAndDoesNotReplaceDefault() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("avp155-presentation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let recipes = RecipeStore(directory: repo.appendingPathComponent("recipes"))
        let primary = try XCTUnwrap(try recipes.loadAll().first { $0.id == "beatsaber140" })
        let variants = recipes.loadVariants()
        let variant = try XCTUnwrap(variants.first { $0.id == primary.id && $0.versionCode == 3237 })
        let paths = Paths(recipes: nil, store: ContentStore(root: root.appendingPathComponent("store")),
                          jobs: JobStore(directory: root.appendingPathComponent("jobs")),
                          packager: ToolchainPackager(root: root.appendingPathComponent("toolchains")))
        let game = Probe.game(variant, draft: false, tested: primary, variants: variants, sources: [],
                              paths: paths, apps: nil, toolchainRevision: nil, bundlePrefix: "test.isolated")
        XCTAssertEqual(game.testedVersion, primary.versionName)
        XCTAssertEqual(game.verifiedVersions.first { $0.versionCode == 3237 }?.kind, .store)
        XCTAssertEqual(game.verifiedVersions.first { $0.isDefault }?.versionCode, 3148)
    }
}
