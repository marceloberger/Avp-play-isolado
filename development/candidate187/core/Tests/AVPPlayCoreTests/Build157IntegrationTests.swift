import XCTest
@testable import AVPPlayCore

final class Build157IntegrationTests: XCTestCase {
    func fixture() throws -> (URL, ToolchainPackager, Recipe) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("build157-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let recipes = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("recipes")
        return (root, ToolchainPackager(root: root), try RecipeStore(directory: recipes).load(id: "batman"))
    }
    func runtime(_ packager: ToolchainPackager, version: Int, commit: String, ancestors: [String], modified: Bool = false) throws -> Toolchain {
        let folder = packager.root.appendingPathComponent("\(version)-\(commit)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("visionos"), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: folder.appendingPathComponent("visionos/run.sh"))
        let data = try JSONSerialization.data(withJSONObject: ["format": 1, "version": version, "commit": commit,
            "ancestors": ancestors, "created": "2026-10-30T00:00:00Z", "modified": modified])
        try data.write(to: folder.appendingPathComponent("toolchain.json"))
        return try Toolchain(root: folder)
    }
    func testHistoricalRuntimesCannotBecomeDefaults() throws {
        let (_, packager, base) = try fixture()
        _ = try runtime(packager, version: 750, commit: "900daf8", ancestors: ["900daf8", "dc1a2a8"])
        _ = try runtime(packager, version: 824, commit: "a61188d", ancestors: ["a61188d", "900daf8", "dc1a2a8", "98e44ec"])
        XCTAssertNil(packager.defaultForRecipe(base))
        var newer = base; newer.toolchain.minCommit = "98e44ec"
        XCTAssertNil(packager.defaultForRecipe(newer))
        XCTAssertNil(packager.functionalDefault())
        XCTAssertFalse(FileManager.default.fileExists(atPath: packager.root.appendingPathComponent("toolchain-choices.json").path))
    }
    func testMissingIncompatibleAndModified824DoNotTriggerImplicitMigration() throws {
        let (_, packager, base) = try fixture()
        _ = try runtime(packager, version: 750, commit: "900daf8", ancestors: ["900daf8", "dc1a2a8"])
        var newer = base; newer.toolchain.minCommit = "98e44ec"
        XCTAssertNil(packager.defaultForRecipe(newer), "850 is mandatory; never migrate to a historical runtime")
        _ = try runtime(packager, version: 824, commit: "a61188d", ancestors: ["a61188d", "98e44ec"], modified: true)
        XCTAssertNil(packager.defaultForRecipe(newer))
        XCTAssertNil(packager.toolchain(for: .init(version: 824, commit: "missing")))
    }
    func testOldJobRequestsAndExplicitPinsRemainUnchanged() throws {
        let (_, packager, recipe) = try fixture()
        let old = try runtime(packager, version: 750, commit: "900daf8", ancestors: ["900daf8", "dc1a2a8"])
        let newer = try runtime(packager, version: 824, commit: "a61188d", ancestors: ["a61188d", "900daf8", "dc1a2a8"])
        let request = InstallRequest(toolchain: old.root.path)
        let bytes = try JSONEncoder().encode(request)
        var choices = ToolchainChoices(); choices.choose(packager.pin(for: newer), for: recipe.id)
        XCTAssertEqual(packager.toolchain(for: try XCTUnwrap(choices.games[recipe.id]))?.version(), 824)
        XCTAssertEqual(try JSONDecoder().decode(InstallRequest.self, from: bytes).toolchain, old.root.path)
        XCTAssertNil(packager.defaultForRecipe(recipe))
    }
    func testOfflineCatalogOnlyAddsDiagnosticsAndRejectsWrongSchema() throws {
        let (root, _, _) = try fixture()
        let path = root.appendingPathComponent("catalog.json")
        let row: [String: Any] = ["requestedTitle": "Sample", "title": "Sample", "package": "com.example.game",
            "target": "x123", "versionName": "1", "versionCode": 1, "classification": "C",
            "limitation": "Inventário incompleto", "evidence": ["https://example.com/source"]]
        try JSONSerialization.data(withJSONObject: ["schema": 1, "entries": [row]]).write(to: path)
        let catalog = try XCTUnwrap(LocalSupportCatalog.load(at: path))
        XCTAssertTrue(catalog.diagnostics(package: "com.other", versionCode: "1").isEmpty)
        XCTAssertTrue(catalog.diagnostics(package: "com.example.game", versionCode: "2").contains { $0.contains("diverge") })
        XCTAssertNil(CommunityKleptonTarget.candidate(package: "com.example.game", versionCode: "1", versionName: "1"))
        try JSONSerialization.data(withJSONObject: ["schema": 2, "entries": [row]]).write(to: path)
        XCTAssertNil(LocalSupportCatalog.load(at: path))
    }
    func testCaveCraveLocalRecipeRequiresCompleteInventoryWithoutMetaDownloads() throws {
        let (root, _, base) = try fixture()
        let recipes = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("recipes")
        let recipe = try RecipeStore(directory: recipes).load(id: "local-7527722310622065")
        XCTAssertEqual(recipe.package, "com.rrrgames.CaveCrave")
        XCTAssertEqual(recipe.versionCode, 739)
        XCTAssertEqual(recipe.toolchain.target, "x7527722310622065")
        XCTAssertEqual(recipe.toolchain.minCommit, "a61188d")
        XCTAssertEqual(recipe.status.playability, "untested")
        XCTAssertNil(recipe.store.appId)
        XCTAssertTrue(recipe.files.allSatisfy { $0.source?.kind == .user && $0.required })
        XCTAssertEqual(recipe.files.count, 22)
        XCTAssertTrue(recipe.files.allSatisfy { $0.sha256 == nil }, "No publisher hashes were fabricated")
        let apk = try LocalAPKVariantTests().makeAPK(in: root, package: recipe.package,
            versionCode: String(recipe.versionCode), versionName: recipe.versionName)
        let discovery = try LocalGameImport().discover(in: root, recipe: recipe, selectedAPK: apk)
        XCTAssertFalse(discovery.canInstall)
        XCTAssertEqual(discovery.missingRequired.count, 21)
        let paths = recipe.files.compactMap(StagePlan.destination)
        XCTAssertEqual(Set(paths).count, 22)
        XCTAssertTrue(paths.contains("Documents/android-files/Android/obb/com.rrrgames.CaveCrave/main.739.com.rrrgames.CaveCrave.obb"))
        XCTAssertEqual(base.id, "batman", "No existing recipe was replaced")
    }

}
