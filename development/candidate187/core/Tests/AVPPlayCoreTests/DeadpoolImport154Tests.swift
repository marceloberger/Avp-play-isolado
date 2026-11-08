import XCTest
@testable import AVPPlayCore

/// Synthetic discovery fixtures only. No import/register, real APK, game or device is used.
final class DeadpoolImport154Tests: XCTestCase {
    func recipe() throws -> Recipe {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try RecipeStore(directory: root.appendingPathComponent("recipes")).load(id: "store-3240283705987790")
    }
    func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("deadpool154-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.resolvingSymlinksInPath()
    }
    func discoveryFixture() throws -> (Recipe, URL, URL) {
        let r = try recipe(), root = try scratch()
        let apk = try LocalAPKVariantTests().makeAPK(in: root, package: r.package, versionCode: String(r.versionCode), versionName: r.versionName)
        for file in r.files where file.required && file.role != "apk" {
            try Data("synthetic test content: \(file.name)".utf8).write(to: root.appendingPathComponent(file.name))
        }
        return (r, root, apk)
    }
    func testOnlyFiveVerifiedAdditionalVoicePacksAreOptional() throws {
        let r = try recipe(); try r.validate()
        XCTAssertEqual(Set(r.files.filter { !$0.required }.map(\.name)), ["de.lang", "es-mx.lang", "es.lang", "fr.lang", "ja.lang"])
        XCTAssertTrue(try XCTUnwrap(r.files.first { $0.name == "en.lang" }).required)
        XCTAssertEqual(r.files.filter(\.required).count, 54)
        XCTAssertTrue(r.files.filter { $0.name.hasSuffix(".pak") }.allSatisfy(\.required))
        for entry in r.assetFiles! { XCTAssertEqual(r.files.first { $0.id == entry.id }?.locale, entry.tag) }
    }
    func testDiscoveryAllowsMissingOptionalLanguagesWithEnglishAndEssentialFiles() throws {
        let (r, root, apk) = try discoveryFixture()
        let found = try LocalGameImport().discover(in: root, recipe: r, selectedAPK: apk)
        XCTAssertTrue(found.canInstall); XCTAssertTrue(found.missingRequired.isEmpty)
        XCTAssertNotNil(found.files["en.lang"])
        XCTAssertNil(found.files["de.lang"])
    }
    func testDiscoveryStillBlocksMissingEnglish() throws {
        let (r, root, apk) = try discoveryFixture()
        try FileManager.default.removeItem(at: root.appendingPathComponent("en.lang"))
        let found = try LocalGameImport().discover(in: root, recipe: r, selectedAPK: apk)
        XCTAssertEqual(found.missingRequired, ["en.lang"]); XCTAssertFalse(found.canInstall)
    }
    func testDiscoveryStillBlocksEveryMissingEssentialContentFile() throws {
        let (r, root, apk) = try discoveryFixture()
        for file in r.files where file.required && file.role != "apk" && file.name != "en.lang" {
            let path = root.appendingPathComponent(file.name), saved = try Data(contentsOf: path)
            try FileManager.default.removeItem(at: path)
            let found = try LocalGameImport().discover(in: root, recipe: r, selectedAPK: apk)
            XCTAssertEqual(found.missingRequired, [file.name]); XCTAssertFalse(found.canInstall)
            try saved.write(to: path)
        }
    }
    func testDiscoveryWithoutAPKCannotInstall() throws {
        let r = try recipe(), root = try scratch()
        let found = try LocalGameImport().discover(in: root, recipe: r)
        XCTAssertFalse(found.canInstall); XCTAssertTrue(found.missingRequired.contains(r.files.first { $0.role == "apk" }!.name))
    }
    func testPresentOptionalLanguageWithWrongPublishedHashIsHeldForManualReview() throws {
        let (r, root, apk) = try discoveryFixture()
        let path = root.appendingPathComponent("fr.lang"), bytes = Data("nonempty synthetic French voice fixture".utf8)
        try bytes.write(to: path)
        let english = root.appendingPathComponent("en.lang"), before = try Data(contentsOf: english)
        let found = try LocalGameImport().discover(in: root, recipe: r, selectedAPK: apk)
        XCTAssertTrue(found.canInstall); XCTAssertNil(found.files["fr.lang"])
        XCTAssertTrue(found.unmatchedFiles.contains { $0.lastPathComponent == "fr.lang" })
        XCTAssertEqual(try Data(contentsOf: path), bytes); XCTAssertEqual(try Data(contentsOf: english), before)
        let all = FetchPlan.wantedFiles(recipe: r, selection: .init(locales: ["fr"]))
        XCTAssertTrue(all.contains { $0.name == "fr.lang" }); XCTAssertTrue(all.contains { $0.name == "en.lang" })
    }
    func testDependencyValidationRequiresEnglishAndAllEssentialData() throws {
        let r = try recipe()
        let assets = r.files.filter { $0.required && $0.role != "apk" }.map {
            LocalAPKAsset(name: $0.name, sourcePath: "/fixture/\($0.name)", size: $0.size!, sha256: $0.sha256!, recipeSizeMatches: true, recipeHashMatches: true)
        }
        var v = LocalAPKVariant(id: "fixture", recipeID: r.id, recipeVersionCode: r.versionCode, relativePath: "fixture.apk", size: 1,
            sha256: String(repeating: "a", count: 64), package: r.package, versionCode: String(r.versionCode), versionName: r.versionName,
            architectures: ["arm64-v8a"], source: "local", trustStatus: "local-unverified", official: false, recipeValidated: false, registeredAt: Date())
        v.assets = assets
        XCTAssertNoThrow(try LocalAPKVariantStore.requireCompatibleDependencies(v, recipe: r))
        XCTAssertNoThrow(try AssetFilesList.validateContent(recipe: r, stagedFiles: [], localVariant: v))
        for asset in assets {
            v.assets = assets.filter { $0.name != asset.name }
            XCTAssertThrowsError(try LocalAPKVariantStore.requireCompatibleDependencies(v, recipe: r), asset.name)
        }
        v.assets = assets; v.assets![0].sha256 = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try LocalAPKVariantStore.requireCompatibleDependencies(v, recipe: r))
    }
    func testFutureStoreRecipePreservesExplicitLanguagesAndKeepsUnknownFilesRequired() throws {
        let r = try recipe(), build = CatalogBuild(buildId: "154", version: "future", versionCode: 9999, fileName: nil)
        let names = [("future.apk", "APK"), ("en.lang", "ASSET"), ("de.lang", "ASSET"), ("unknown.lang", "ASSET"), ("audio_all.pak", "ASSET")]
        let files = names.enumerated().map { ListedFile(name: $0.element.0, id: String(100 + $0.offset), kind: $0.element.1, sizeText: "1MB") }
        let draft = try StoreUpdate.make(tested: r, build: build, files: files)
        XCTAssertFalse(try XCTUnwrap(draft.files.first { $0.name == "de.lang" }).required)
        XCTAssertEqual(draft.files.first { $0.name == "de.lang" }?.locale, "de")
        for name in ["en.lang", "unknown.lang", "audio_all.pak"] { XCTAssertTrue(try XCTUnwrap(draft.files.first { $0.name == name }).required) }
    }
    func testAPKNeverBecomesOptionalInRecipeValidation() throws {
        var r = try recipe(); let i = r.files.firstIndex { $0.role == "apk" }!
        r.files[i].required = false
        XCTAssertThrowsError(try r.validate())
    }
}

final class RuntimeAPKManifest154Tests: XCTestCase {
    func fixture() throws -> (Recipe, RecipeFile, URL, SHA256FileCache) {
        var r = try CommunityAPKStage152Tests().frozenRecipe()
        r.id = "fixture154"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("apk154-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let apk = root.appendingPathComponent("selected-variant.apk")
        try Data("nonempty synthetic complete APK bytes".utf8).write(to: apk)
        return (r, r.files[0], apk, SHA256FileCache(root: root.appendingPathComponent("cache")))
    }
    func testFrozenRecipeWithoutDestIncludesAPKInCopyAndFinalVerificationManifest() throws {
        let (r, file, apk, cache) = try fixture(), size = ContentStore.fileSize(apk)!
        let local = [(file: file, url: apk, size: size)]
        let plan = StagePlan.plan(local: local, remote: [:])
        let entries = try InstallationContent.recipeEntries(recipe: r, local: local, cache: cache)
        XCTAssertEqual(entries.map(\.destination), plan.map(\.destination))
        XCTAssertEqual(entries.first?.destination, "Documents/x6072194326150034.apk")
        XCTAssertEqual(entries.first?.sha256, try Hashing.sha256(of: apk)); XCTAssertNil(r.files[0].dest)
    }
    func testDroppedMissingOrMisdirectedAPKCannotProduceFinalStageManifest() throws {
        let (r, file, apk, cache) = try fixture()
        XCTAssertThrowsError(try InstallationContent.recipeEntries(recipe: r, local: [], cache: cache))
        var wrong = file; wrong.localName = "wrong.apk"
        XCTAssertThrowsError(try InstallationContent.recipeEntries(recipe: r, local: [(wrong, apk, 1)], cache: cache))
        XCTAssertThrowsError(try InstallationContent.recipeEntries(recipe: r, local: [(file, apk.appendingPathExtension("missing"), 1)], cache: cache))
    }
    func testExplicitAPKDestinationsAndResolvedAliasesRemainExact() throws {
        var (r, file, apk, cache) = try fixture()
        file.localName = "re4.apk"; file.dest = "explicit"; r.files = [file]
        let entries = try InstallationContent.recipeEntries(recipe: r, local: [(file, apk, ContentStore.fileSize(apk)!)], cache: cache)
        XCTAssertEqual(entries.first?.destination, "Documents/explicit/re4.apk")
    }
    func testCorruptSourceDigestIsRejectedBeforeTransfer() throws {
        var (r, file, apk, cache) = try fixture()
        file.sha256 = String(repeating: "0", count: 64); r.files = [file]
        XCTAssertThrowsError(try InstallationContent.recipeEntries(recipe: r, local: [(file, apk, ContentStore.fileSize(apk)!)], cache: cache))
    }
    func testFinalVerificationCannotSucceedWhenAPKCopyDoesNotArrive() throws {
        let (r, file, apk, cache) = try fixture()
        let entries = try InstallationContent.recipeEntries(recipe: r, local: [(file, apk, ContentStore.fileSize(apk)!)], cache: cache)
        var puts = 0
        XCTAssertThrowsError(try InstallationContent.sync(entries, container: .init(stat: { _ in nil }, fetch: { _, _ in XCTFail() }, put: { _, _ in puts += 1 }), receipts: apk.deletingLastPathComponent().appendingPathComponent("receipts.json")))
        XCTAssertEqual(puts, 1)
    }
}
