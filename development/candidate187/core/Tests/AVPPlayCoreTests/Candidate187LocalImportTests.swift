import XCTest
@testable import AVPPlayCore

final class Candidate187LocalImportTests: XCTestCase {
    /// Explicit local inputs only. The app and its installed data are never opened.
    func testParadiseCanBeImportedAgainOfflineIntoAnEmptyDisposableLibrary() throws {
        guard let path = ProcessInfo.processInfo.environment["AVP187_READONLY_PARADISE_INPUT"] else {
            throw XCTSkip("Supply original local APK/OBBs explicitly; never discover old libraries automatically")
        }
        let input = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("c187-new-import-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let analysis = LocalProvisionalRecipeStore(root: root.appendingPathComponent("provisional-recipes"))
        let found = try LocalGameImport().createProvisionalAnalysis(from: input, store: analysis)
        let revised = try analysis.setExperimentalTarget(appID: "8826022237415280",
            provenance: "AppID supplied by the user for Propagation: Paradise Hotel", for: found.id)
        let recipe = try XCTUnwrap(revised.experimentalRecipe, revised.experimentalBlockers.joined(separator: "; "))
        XCTAssertEqual(recipe.package, "com.wanadev.propagation_ph")
        XCTAssertEqual(recipe.versionCode, 47)
        XCTAssertEqual(recipe.versionName, "1.3.1")
        XCTAssertEqual(recipe.toolchain.target, DraftRecipe.genericTarget(appId: "8826022237415280"))
        XCTAssertNil(recipe.store.appId)
        let discovery = try LocalGameImport().discover(in: input, recipe: recipe)
        let destinations = LocalGameImport().automaticAdditionalDestinations(for: discovery, recipe: recipe)
        let registry = LocalAPKVariantStore(root: root.appendingPathComponent("local-variants"))
        let variant = try LocalGameImport().register(discovery, recipe: recipe, store: registry,
            additionalDestinations: destinations, automaticAdditionalPaths: Set(destinations.keys))
        XCTAssertEqual(variant.trustStatus, "local-unverified")
        XCTAssertFalse(variant.official)
        XCTAssertEqual(variant.assets?.filter { URL(fileURLWithPath: $0.sourcePath).pathExtension == "obb" }.count, 2)
        let selected = try registry.validatedForPreparation(id: variant.id, for: recipe)
        try LocalExperimentalAdmission.requireValidated(recipe: recipe, selected: selected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("jobs").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("build-only").path))
        print("C187_OFFLINE_IMPORT package=\(variant.package) version=\(variant.versionCode) assets=\(variant.assets?.count ?? 0) eligible=true jobs=0 builds=0")
    }
}
