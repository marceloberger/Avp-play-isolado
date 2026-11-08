import XCTest
@testable import AVPPlayCore

final class AutomaticAPKIdentityTests: XCTestCase {
    func testBundledLaserIdentityIsPublicAndDoesNotCertifyCompatibility() throws {
        let identity = try XCTUnwrap(AutomaticAPKIdentity.resolve(package: "com.Breach.LaserMatrix"))
        XCTAssertEqual(identity.appID, "8840783592704373")
        XCTAssertEqual(identity.source, "https://avpplay.martek.de/api/v1/games/8840783592704373")
        XCTAssertTrue(identity.isValid)
        let shipped = try XCTUnwrap(AutomaticAPKIdentity.resolve(package: "com.twistedpixelgames.PILO"))
        XCTAssertEqual(shipped.appID, "3240283705987790")
        XCTAssertTrue(shipped.source.contains("github.com/myMartek/avp-play/blob/"))
        XCTAssertNil(AutomaticAPKIdentity.resolve(package: "com.unknown.game"))
        XCTAssertNil(AutomaticAPKIdentity.resolve(package: "com.breach.lasermatrix"))
    }

    func testConflictingInvalidOrInventedBindingsFailClosed() {
        let a = AutomaticAPKIdentity(title: "A", package: "com.example.game", appID: "123456", source: "https://avpplay.martek.de/api/v1/games/123456")
        let b = AutomaticAPKIdentity(title: "B", package: a.package, appID: "654321", source: "https://avpplay.martek.de/api/v1/games/654321")
        XCTAssertNil(AutomaticAPKIdentity.resolve(package: a.package, entries: [a,b]))
        for id in ["com.example.game", "x123456", "１２３４５６", "12", String(repeating: "1", count: 25)] {
            XCTAssertFalse(LocalExperimentalTarget.isValidAppID(id))
        }
        XCTAssertFalse(AutomaticAPKIdentity(title: "A", package: a.package, appID: a.appID, source: "https://example.com/123456").isValid)
        XCTAssertFalse(AutomaticAPKIdentity(title: "A", package: a.package, appID: a.appID, source: b.source).isValid)
    }

    func testSyntheticLaserAPKAutomaticallyCreatesPermitted850RecipeWithoutNetworkOrBuild() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let apk = try LocalAPKVariantTests().makeAPK(in: root, package: "com.Breach.LaserMatrix", versionCode: "519", versionName: "1.0.0",
            nativeLibraries: ["libmain.so", "libunity.so", "libil2cpp.so"])
        let original = try Hashing.sha256(of: apk)
        let store = LocalProvisionalRecipeStore(root: root.appendingPathComponent("analysis"))
        var record = try store.create(from: apk)
        XCTAssertEqual(record.title, "Laser Matrix")
        XCTAssertEqual(record.genericAnalysis.engine, .unity)
        XCTAssertEqual(record.genericAnalysis.entrypoint, "libmain")
        let recipe = try XCTUnwrap(record.experimentalRecipe)
        XCTAssertEqual(recipe.toolchain.target, "x8840783592704373")
        XCTAssertEqual(recipe.toolchain.minCommit, "cc2856c")
        XCTAssertEqual(recipe.status.playability, "untested")
        XCTAssertNil(recipe.store.appId, "Local analysis must not enable commercial downloads")
        XCTAssertNoThrow(try recipe.validateForJob())
        XCTAssertEqual(original, try Hashing.sha256(of: apk))
        let loaded = try XCTUnwrap(store.loadAll().first)
        XCTAssertEqual(loaded.apkSHA256, record.apkSHA256)
        XCTAssertEqual(loaded.experimentalTarget, record.experimentalTarget)
        XCTAssertEqual(loaded.package, record.package)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("jobs").path))
        let good = root.appendingPathComponent("main.519.com.Breach.LaserMatrix.obb")
        let other = root.appendingPathComponent("main.519.com.other.game.obb")
        try Data("test-good".utf8).write(to: good); try Data("test-other".utf8).write(to: other)
        record = try store.associate([good], with: record.id)
        XCTAssertEqual(record.externalFiles.first?.destination, "android-files/obb")
        XCTAssertEqual(record.externalFiles.first?.sha256, try Hashing.sha256(of: good))
        XCTAssertNotNil(record.experimentalRecipe)
        let asset = root.appendingPathComponent("content.bundle")
        try Data("synthetic-content".utf8).write(to: asset)
        record = try store.associate([asset], with: record.id)
        record = try store.mapExternalFile(asset.resolvingSymlinksInPath().path, kind: "asset", destination: "android-files/obb",
            evidence: "Synthetic user-selected asset mapping", for: record.id)
        record = try store.setExperimentalTarget(appID: "8840783592704373",
            provenance: "https://avpplay.martek.de/api/v1/games/8840783592704373", for: record.id)
        XCTAssertNotNil(record.experimentalRecipe, "Reactivation must preserve explicitly validated asset mapping")
        record = try store.associate([other], with: record.id)
        XCTAssertNil(record.externalFiles.last?.destination, "A filename from another package cannot inherit the layout")
        XCTAssertNil(record.experimentalRecipe, "Unmapped external content blocks actions")
    }

    func testUnknownPackageAndUnsupportedEngineRemainAnalysisOnly() throws {
        for (package, libs) in [("com.unknown.game", ["libmain.so", "libunity.so"]),
                                 ("com.Breach.LaserMatrix", ["libunknown.so"])] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let apk = try LocalAPKVariantTests().makeAPK(in: root, package: package, nativeLibraries: libs)
            let record = try LocalProvisionalRecipeStore(root: root.appendingPathComponent("analysis")).create(from: apk)
            XCTAssertNil(record.experimentalTarget)
            XCTAssertNil(record.experimentalRecipe)
            XCTAssertFalse(record.automaticTargetBlockers.isEmpty)
        }
    }

    func testFolderAnalysisNeverChoosesBetweenTwoAPKs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("one.apk")
        try Data([1]).write(to: first)
        XCTAssertEqual(LocalGameImport().uniqueAPK(in: root)?.resolvingSymlinksInPath(), first.resolvingSymlinksInPath())
        try Data([2]).write(to: root.appendingPathComponent("two.apk"))
        XCTAssertNil(LocalGameImport().uniqueAPK(in: root))
    }

    func testExistingOfficialRecipesStayAuthoritativeAndUnchanged() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("recipes")
        let before = try RecipeStore(directory: root).loadAll()
        for recipe in before { _ = AutomaticAPKIdentity.resolve(package: recipe.package) }
        let after = try RecipeStore(directory: root).loadAll()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(before), try encoder.encode(after))
        XCTAssertTrue(before.contains { $0.id == "store-3240283705987790" })
    }

    func testPublishedGhostTownLayoutAndIncompatibleEditionStayConservative() throws {
        let ghost = try XCTUnwrap(AutomaticAPKIdentity.resolve(package: "com.FireproofStudios.GhostTown"))
        XCTAssertEqual(ghost.obbDirectory, "Android/obb/com.FireproofStudios.GhostTown")
        XCTAssertEqual(ghost.requiresExternalContent, true)
        let edition = try XCTUnwrap(AutomaticAPKIdentity.resolve(package: "com.sumalab.CrisisBrigade2reloaded"))
        XCTAssertEqual(edition.catalogStatus, "incompatible")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let apk = try LocalAPKVariantTests().makeAPK(in: root, package: edition.package, nativeLibraries: ["libUE4.so"])
        let record = try LocalProvisionalRecipeStore(root: root.appendingPathComponent("analysis")).create(from: apk)
        XCTAssertNil(record.experimentalRecipe)
        XCTAssertTrue(record.automaticTargetBlockers.contains { $0.contains("incompatibilidade") })
    }

    func testIsolatedPrepareRejects750BeforeCreatingWorkspace() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("visionos"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("#!/bin/sh\n".utf8).write(to: root.appendingPathComponent("visionos/run.sh"))
        let recipes = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("recipes")
        let recipe = try RecipeStore(directory: recipes).load(id: "batman")
        let workspace = root.appendingPathComponent("must-not-exist")
        XCTAssertThrowsError(try LocalAPKPreparer().prepareIsolated(recipe: recipe, variantID: "missing", store: ContentStore(root: root),
            toolchain: Toolchain(root: root), localVariants: LocalAPKVariantStore(root: root.appendingPathComponent("variants")), workspaceRoot: workspace))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.path))
    }
}
