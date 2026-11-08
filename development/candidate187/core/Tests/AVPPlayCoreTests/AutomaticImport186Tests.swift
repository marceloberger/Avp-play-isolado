import XCTest
@testable import AVPPlayCore

final class AutomaticImport186Tests: XCTestCase {
    private func fixture(online: Bool = false, extra: String = "content.pak") throws -> (URL, URL, LocalProvisionalRecipeStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("auto186-" + UUID().uuidString)
        let input = root.appendingPathComponent("inputs")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        let package = online ? "com.example.auto186" : "com.Breach.LaserMatrix"
        _ = try LocalAPKVariantTests().makeAPK(in: input, package: package, versionCode: "519", versionName: "1.0.0",
            nativeLibraries: ["libmain.so", "libunity.so", "libil2cpp.so"])
        // makeAPK's construction directory is not part of the user's input selection.
        try FileManager.default.removeItem(at: input.appendingPathComponent("synthetic-apk"))
        for name in ["main.519.\(package).obb", "patch.519.\(package).obb", extra] {
            try Data(("synthetic " + name).utf8).write(to: input.appendingPathComponent(name))
        }
        return (root, input, LocalProvisionalRecipeStore(root: root.appendingPathComponent("analysis")))
    }
    private func catalog(_ id: String = "123456789", status: String = "community") -> CatalogGame {
        .init(appId: id, title: "Synthetic", package: "com.example.auto186", status: status, works: 0, problems: 0, fails: 0)
    }

    func testOfflineAndOnlineActivateMapAndRegisterWithoutManualFields() async throws {
        for online in [false, true] {
            let (root, input, store) = try fixture(online: online)
            defer { try? FileManager.default.removeItem(at: root) }
            var record = try LocalGameImport().createProvisionalAnalysis(from: input, store: store)
            if online {
                let game = catalog()
                record = try await store.resolveOnlineIdentity(for: record.id) { _, _ in .init(games: [game], more: false) }
            }
            let recipe = try XCTUnwrap(record.experimentalRecipe, record.experimentalBlockers.joined(separator: ";"))
            XCTAssertEqual(recipe.toolchain.target, online ? "x123456789" : "x8840783592704373")
            XCTAssertEqual(recipe.toolchain.minCommit, "cc2856c")
            XCTAssertNil(record.experimentalDraft185)
            XCTAssertEqual(record.externalFiles.count, 3)
            XCTAssertTrue(record.externalFiles.allSatisfy(\.isSafeForExperimentalRecipe))
            XCTAssertEqual(record.externalFiles.filter { $0.kind == "obb" }.count, 2)
            XCTAssertEqual(record.externalFiles.first { $0.fileName == "content.pak" }?.destination, "android-files/obb")
            try recipe.validateForJob()
            let found = try LocalGameImport().discover(in: input, recipe: recipe)
            let destinations = LocalGameImport().automaticAdditionalDestinations(for: found, recipe: recipe)
            XCTAssertEqual(destinations.count, 3)
            let variants = LocalAPKVariantStore(root: root.appendingPathComponent("variants"))
            let variant = try LocalGameImport().register(found, recipe: recipe, store: variants,
                additionalDestinations: destinations, automaticAdditionalPaths: Set(destinations.keys))
            XCTAssertEqual(variant.assets?.count, 3)
            XCTAssertTrue(variant.assets?.allSatisfy { $0.automaticallyIncluded == true } == true)
            _ = try variants.validatedForPreparation(id: variant.id, for: recipe)
            try Data("mutated".utf8).write(to: input.appendingPathComponent("content.pak"))
            XCTAssertThrowsError(try LocalGameImport().register(found, recipe: recipe, store: variants, additionalDestinations: destinations))
            XCTAssertThrowsError(try variants.validatedForPreparation(id: variant.id, for: recipe))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("jobs").path))
        }
    }

    func testOfflineAndOnlinePrepareWithExplicitDisposable850Fixture() async throws {
        guard let path = ProcessInfo.processInfo.environment["AVPPLAY_TEST_TEMP_RUNTIME850"] else {
            throw XCTSkip("Supply a verified runtime extracted under /private/tmp; installed runtimes are never read")
        }
        let source = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let temporary = URL(fileURLWithPath: "/private/tmp").resolvingSymlinksInPath().path
        guard source.path.hasPrefix(temporary + "/") else { throw LocalAPKVariantError.invalidRecord("Runtime fixture must be disposable") }
        let runtime = try Toolchain(root: source)
        try RuntimePolicy177.requireSource(runtime)
        for online in [false, true] {
            let (root, input, store) = try fixture(online: online)
            defer { try? FileManager.default.removeItem(at: root) }
            var record = try LocalGameImport().createProvisionalAnalysis(from: input, store: store)
            if online {
                let game = catalog()
                record = try await store.resolveOnlineIdentity(for: record.id) { _, _ in .init(games: [game], more: false) }
            }
            let recipe = try XCTUnwrap(record.experimentalRecipe)
            let found = try LocalGameImport().discover(in: input, recipe: recipe)
            let destinations = LocalGameImport().automaticAdditionalDestinations(for: found, recipe: recipe)
            let registry = LocalAPKVariantStore(root: root.appendingPathComponent("variants"))
            let variant = try LocalGameImport().register(found, recipe: recipe, store: registry,
                additionalDestinations: destinations, automaticAdditionalPaths: Set(destinations.keys))
            let prepared = try LocalAPKPreparer().prepareIsolated(recipe: recipe, variantID: variant.id,
                store: ContentStore(root: root.appendingPathComponent("content")), toolchain: runtime,
                localVariants: registry, workspaceRoot: root.appendingPathComponent("prepare"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.appendingPathComponent(".qi-prepared").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.appendingPathComponent("lib/arm64-v8a/libmain.so").path))
            let command = BuildOnlyPipeline.compileCommand(project: root.appendingPathComponent("fixture.xcodeproj"), product: "fixture", derivedData: root.appendingPathComponent("derived"))
            XCTAssertTrue(BuildOnlyPipeline.isSafe(command))
            XCTAssertTrue(command.arguments.contains("CODE_SIGNING_ALLOWED=NO"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("jobs").path))
        }
    }

    func testUnknownAssetAndWrongPackageOBBRemainPending() throws {
        for extra in ["unknown.blob", "main.519.com.other.game.obb", "main.520.com.Breach.LaserMatrix.obb"] {
            let (root, input, store) = try fixture(extra: extra)
            defer { try? FileManager.default.removeItem(at: root) }
            let record = try LocalGameImport().createProvisionalAnalysis(from: input, store: store)
            XCTAssertNil(record.experimentalRecipe)
            XCTAssertNil(record.externalFiles.first { $0.fileName == extra }?.destination)
        }
    }

    func testDuplicateBasenamesNeverChooseFirstAndLateCollisionBlocks() throws {
        let (root, input, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var record = try LocalGameImport().createProvisionalAnalysis(from: input, store: store)
        XCTAssertNotNil(record.experimentalRecipe)
        let other = root.appendingPathComponent("another")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let collision = other.appendingPathComponent("content.pak")
        try Data("different".utf8).write(to: collision)
        record = try store.associate([collision], with: record.id)
        XCTAssertNil(record.experimentalRecipe)
        let paths = [input.appendingPathComponent("content.pak"), collision, input.appendingPathComponent("main.519.com.Breach.LaserMatrix.obb")]
        let inferred = LocalGameImport.automaticRuntimeDestinations(files: paths, package: record.package, versionCode: "519", target: "x8840783592704373", engine: .unity)
        XCTAssertNil(inferred[collision.path])
        XCTAssertNil(inferred[input.appendingPathComponent("content.pak").path])
    }

    func testRecognizedExtensionAloneDoesNotInventDestination() throws {
        let (root, input, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = input.appendingPathComponent("content.pak")
        XCTAssertTrue(LocalGameImport.automaticRuntimeDestinations(files: [file], package: "com.Breach.LaserMatrix", versionCode: "519", target: "x8840783592704373", engine: .unity).isEmpty)
    }

    func testOnlineConflictsIncompatibilityAndManualDraftAreNotActivated() async throws {
        for mode in ["conflict", "incompatible", "manual", "changed-apk"] {
            let (root, input, store) = try fixture(online: true)
            defer { try? FileManager.default.removeItem(at: root) }
            var record = try LocalGameImport().createProvisionalAnalysis(from: input, store: store)
            if mode == "manual" { record = try store.saveExperimentalDraft(appID: "", provenance: "", for: record.id) }
            if mode == "changed-apk" {
                var bytes = try Data(contentsOf: input.appendingPathComponent("synthetic.apk")); bytes.append(0)
                try bytes.write(to: input.appendingPathComponent("synthetic.apk"))
            }
            let games = mode == "conflict" ? [catalog(), catalog("987654321")] : [catalog(status: mode == "incompatible" ? "incompatible" : "community")]
            record = try await store.resolveOnlineIdentity(for: record.id) { _, _ in .init(games: games, more: false) }
            XCTAssertNil(record.experimentalTarget, mode)
            XCTAssertNil(record.experimentalRecipe, mode)
            if mode == "manual" { XCTAssertNotNil(record.experimentalDraft185) }
        }
    }

    func testPreviouslyReviewedUnknownAssetIsReusedWithoutAnotherReview() throws {
        let (root, input, store) = try fixture(extra: "known.bundle")
        defer { try? FileManager.default.removeItem(at: root) }
        var record = try LocalGameImport().createProvisionalAnalysis(from: input, store: store)
        XCTAssertNil(record.experimentalRecipe)
        let asset = input.appendingPathComponent("known.bundle")
        record = try store.mapExternalFile(asset.path, kind: "asset", destination: "android-files/obb", evidence: "Synthetic fixture: previously reviewed destination", for: record.id)
        let recipe = try XCTUnwrap(record.experimentalRecipe)
        let found = try LocalGameImport().discover(in: input, recipe: recipe)
        let inferred = LocalGameImport().automaticAdditionalDestinations(for: found, recipe: recipe)
        XCTAssertEqual(inferred[asset.path], "android-files/obb/known.bundle")
        let registry = LocalAPKVariantStore(root: root.appendingPathComponent("variants"))
        let variant = try LocalGameImport().register(found, recipe: recipe, store: registry, additionalDestinations: inferred)
        _ = try registry.validatedForPreparation(id: variant.id, for: recipe)
        try Data("tampered".utf8).write(to: asset)
        let newHash = try Hashing.sha256(of: asset)
        XCTAssertThrowsError(try LocalGameImport().register(found, recipe: recipe, store: registry,
            additionalDestinations: inferred, expectedAdditionalHashes: [asset.path: newHash]))
    }

    func testRecipeDirectoryReuseAndAmbiguityDoNotInventOrOverrideDestinations() throws {
        let (root, input, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = try LocalGameImport().createProvisionalAnalysis(from: input, store: store)
        var recipe = try XCTUnwrap(record.experimentalRecipe)
        // A recognized extra outside the runtime layout can reuse one proven recipe directory.
        recipe.localExperimental = nil
        recipe.files.append(.init(name: "known.pak", role: "asset", id: "fixture", required: false, dest: "android-files/content", localName: "known.pak"))
        let found = try LocalGameImport().discover(in: input, recipe: recipe)
        let reused = LocalGameImport().automaticAdditionalDestinations(for: found, recipe: recipe)
        XCTAssertEqual(reused[input.appendingPathComponent("content.pak").path], "android-files/content/content.pak")
        recipe.files.append(.init(name: "another.pak", role: "asset", id: "fixture2", required: false, dest: "android-files/other", localName: "another.pak"))
        XCTAssertTrue(LocalGameImport().automaticAdditionalDestinations(for: found, recipe: recipe).isEmpty)
    }

    func testSavedIdentityCanResumeActivationWithoutNetwork() async throws {
        let (root, input, store) = try fixture(online: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var record = try LocalGameImport().createProvisionalAnalysis(from: input, store: store)
        record.onlineIdentity186 = AutomaticAPKIdentity(title: "Synthetic", package: record.package, appID: "123456789", source: "https://avpplay.martek.de/api/v1/games/123456789")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: store.root.appendingPathComponent(record.id + ".json"))
        record = try await store.resolveOnlineIdentity(for: record.id) { _, _ in XCTFail("Should reuse saved identity"); throw CatalogError.unexpected }
        XCTAssertNotNil(record.experimentalRecipe)
    }
}
