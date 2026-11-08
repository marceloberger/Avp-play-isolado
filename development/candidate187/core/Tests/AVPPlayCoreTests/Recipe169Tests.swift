import XCTest
@testable import AVPPlayCore

final class Recipe169Tests: XCTestCase {
    private func fixture(_ id: String, _ source: String = "isolated168") throws -> Recipe {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures169/\(id)-\(source).json")
        return try JSONDecoder().decode(Recipe.self, from: Data(contentsOf: url))
    }
    private func apk(_ libs: [String] = ["libmain.so", "libunity.so"], split: String? = nil) -> ApkUnpacker.Inspection {
        .init(package: "com.example.game", versionCode: "42", versionName: "1.0", architectures: ["arm64-v8a"], files: 3,
            nativeLibraries: libs.map { "lib/arm64-v8a/" + $0 }, splitName: split)
    }
    private func record(_ refs: [String]) throws -> LocalProvisionalRecipe {
        var record = LocalProvisionalRecipe(apkSHA256: String(repeating: "a", count: 64), apkSize: 10,
            apkPath: "/tmp/synthetic.apk", title: "Synthetic", package: "com.example.game", versionName: "1.0", versionCode: "42",
            architectures: ["arm64-v8a"], nativeLibraries: ["lib/arm64-v8a/libmain.so", "lib/arm64-v8a/libunity.so"], assets: [],
            externalFileReferences: refs, externalFiles: [], createdAt: Date(timeIntervalSince1970: 0))
        record.experimentalTarget = try LocalExperimentalTarget(appID: "123456", provenance: "manual documented fixture", analysis: record.genericAnalysis)
        return record
    }
    func testManifestRetainsLibraryDeclarationsAndSplitIdentity() {
        let xml = #"<manifest package="com.example.game" split="config.arm64"><uses-library android:name="org.apache.http.legacy" /></manifest>"#
        XCTAssertEqual(ApkUnpacker.elementValues("manifest", attribute: "split", in: xml), ["config.arm64"])
        XCTAssertEqual(ApkUnpacker.elementValues("uses-library", attribute: "android:name", in: xml), ["org.apache.http.legacy"])
        XCTAssertTrue(LocalRecipeAnalysis169.inspect(apk(split: "config.arm64")).diagnostics.contains { $0.code == "split-apk" && $0.severity == .error })
    }
    func testUnknownAppIDAndTLSAreReviewableWarningsAndDoNotInventIdentity() {
        let report = LocalRecipeAnalysis169.inspect(apk(["libunity.so", "libmain.so", "libssl.so"]))
        XCTAssertNil(report.decisions.first { $0.field == "appID" }?.value)
        XCTAssertTrue(report.diagnostics.contains { $0.code == "tls-risk" && $0.severity == .warning })
        XCTAssertTrue(report.canReviewForPrepare)
        XCTAssertEqual(report.decisions.first { $0.field == "engine" }?.evidence, "inferred")
    }
    func testConfirmedEntrypointAbsenceIsError() {
        XCTAssertFalse(LocalRecipeAnalysis169.inspect(apk(["libunity.so"])).canReviewForPrepare)
        XCTAssertTrue(LocalRecipeAnalysis169.inspect(apk(["libunity.so"])).diagnostics.contains { $0.message.contains("libmain.so") && $0.severity == .error })
    }
    func testAllExplicitOBBReferencesAreRequiredButStorageHeuristicsAreWarnings() throws {
        let record = try record(["main.42.game.obb patch.42.game.obb"])
        XCTAssertEqual(record.contentDiagnostics169.filter { $0.severity == .error }.count, 2)
        XCTAssertNil(record.experimentalRecipe)
        let inconclusive = try self.record(["/storage/emulated/0/Android/obb"])
        XCTAssertEqual(inconclusive.contentDiagnostics169.first?.severity, .warning)
        XCTAssertNotNil(inconclusive.experimentalRecipe)
        XCTAssertEqual(inconclusive.experimentalRecipe?.status.playability, "untested")
    }
    func testNativeActivityOBBLayoutMatches824WithoutGuessingEntrypoint() throws {
        var record = try record([])
        record = LocalProvisionalRecipe(apkSHA256: record.apkSHA256, apkSize: 10, apkPath: record.apkPath, title: "Native",
            package: record.package, versionName: "1", versionCode: "42", architectures: ["arm64-v8a"],
            nativeLibraries: ["lib/arm64-v8a/libgame.so"], assets: [], externalFileReferences: [],
            hasNativeActivity: true, nativeActivityLibrary: "game", externalFiles: [], createdAt: record.createdAt)
        XCTAssertEqual(record.genericOBBDirectory, "android-files/Android/obb/com.example.game")
        XCTAssertEqual(record.genericAnalysis.entrypoint, "libgame")
    }
    func testBeatSaberVersionsKeepIndependentContentAndDeliveredAssets() throws {
        let old = try fixture("beatsaber140"), original = try fixture("beatsaber140", "original")
        XCTAssertEqual(old.versionCode, 3148); XCTAssertEqual(original.versionCode, 3237)
        XCTAssertEqual(old.toolchain.target, original.toolchain.target)
        XCTAssertEqual(old.addons?.kind, .deliveredAssets)
        XCTAssertEqual(old.files.count, 2); XCTAssertTrue(old.files.allSatisfy(\.required))
        XCTAssertNotEqual(old.files.first?.sha256, original.files.first?.sha256)
        XCTAssertEqual(old.addons?.items?.count, 280)
        XCTAssertEqual(old.store.pinned, original.store.pinned)
        var inspected = apk(); inspected.package = old.package; inspected.versionCode = "3237"
        let selection = RecipeSelection169.inspect(inspected, recipes: [old, original])
        XCTAssertEqual(selection.compatible.map(\.versionCode), [3237])
        XCTAssertEqual(selection.previousVersions.map(\.versionCode), [3148])
        XCTAssertEqual(old.versionCode, 3148, "review never overwrites a recipe")
    }
    func testDeadpoolPreservesEveryLanguageAndKeepsEnglishRequired() throws {
        let original = try fixture("store-3240283705987790", "original"), isolated = try fixture("store-3240283705987790")
        XCTAssertEqual(original.files.count, 59); XCTAssertEqual(isolated.files.count, 59)
        XCTAssertEqual(original.files.map(\.name), isolated.files.map(\.name))
        XCTAssertEqual(original.files.map(\.sha256), isolated.files.map(\.sha256))
        let languages = isolated.files.filter { $0.locale != nil }
        XCTAssertEqual(Set(languages.compactMap(\.locale)), ["en", "de", "es-MX", "es", "fr", "ja"])
        XCTAssertEqual(languages.filter(\.required).map(\.locale), ["en"])
        XCTAssertEqual(original.files.filter(\.required).count, 59)
        XCTAssertEqual(isolated.files.filter(\.required).count, 54)
    }
    func testElixirClassificationDoesNotChangeConversionInputs() throws {
        let a = try fixture("store-3793077684043441", "original"), b = try fixture("store-3793077684043441")
        XCTAssertEqual(a.status.playability, "verified"); XCTAssertEqual(b.status.playability, "untested")
        XCTAssertEqual(a.files, b.files); XCTAssertEqual(a.toolchain.target, b.toolchain.target)
        XCTAssertEqual(a.versionCode, b.versionCode)
    }
    func testBodycombatPurchaseListDoesNotProveDLCContentOrOwnership() throws {
        let a = try fixture("store-4015163475201433", "original"), b = try fixture("store-4015163475201433")
        XCTAssertEqual(a.addons?.kind, .purchaseList); XCTAssertNil(b.addons)
        XCTAssertEqual(a.files, b.files); XCTAssertEqual(a.files.count, 38)
        XCTAssertTrue(a.files.allSatisfy(\.required))
        XCTAssertNil(a.addons?.items, "original declares a purchase-list mechanism, not owned SKUs")
    }
    func testSwiftRulesMatchArchived824ResolverOnSyntheticInputs() throws {
        struct Row: Decodable { let libraries: [String]; let native: String?; let package: String; let target: String; let kind: String; let entry: String; let obb: String }
        struct Snapshot: Decodable { let sourceSHA256: String; let cases: [Row] }
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures169/resolver824.json")
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: path))
        XCTAssertEqual(snapshot.cases.count, 6)
        for row in snapshot.cases {
            let analysis = LocalGenericTargetAnalysis.analyze(package: row.package, versionCode: "42", architectures: ["arm64-v8a"],
                nativeLibraries: row.libraries.map { "lib/arm64-v8a/" + $0 }, hasNativeActivity: row.native != nil, nativeActivityLibrary: row.native)
            XCTAssertEqual(analysis.entrypoint, row.entry)
            XCTAssertEqual(analysis.engine.map(Klepton824RecipeRules.engineName), row.kind)
            var record = LocalProvisionalRecipe(apkSHA256: String(repeating: "c", count: 64), apkSize: 10, apkPath: "/tmp/synthetic.apk",
                title: "Fixture", package: row.package, versionName: "1", versionCode: "42", architectures: ["arm64-v8a"],
                nativeLibraries: row.libraries.map { "lib/arm64-v8a/" + $0 }, assets: [], externalFileReferences: [],
                hasNativeActivity: row.native != nil, nativeActivityLibrary: row.native, externalFiles: [], createdAt: Date(timeIntervalSince1970: 0))
            record.experimentalTarget = try LocalExperimentalTarget(appID: String(row.target.dropFirst()), provenance: "pinned 824 resolver fixture", analysis: analysis)
            XCTAssertEqual(record.genericOBBDirectory, "android-files/" + row.obb)
        }
    }

    func testReuseKeyInvalidatesForRecipeAssetsIdentityAndTLSChanges() throws {
        let recipe = try fixture("beatsaber140"), hash = String(repeating: "a", count: 64)
        func key(_ recipe: Recipe, assets: [String: String] = [:], identity: String = "identity", tls: String = "tls168") throws -> AnalysisReuseKey169 {
            try .init(apkSHA256: hash, recipe: recipe, assets: assets, identitySnapshot: Data(identity.utf8), tlsOverlay: Data(tls.utf8))
        }
        let baseline = try key(recipe)
        XCTAssertEqual(baseline, try key(recipe))
        var changed = recipe; changed.toolchain.target = "different"
        XCTAssertNotEqual(baseline, try key(changed))
        XCTAssertNotEqual(baseline, try key(recipe, assets: ["obb/main.obb": hash]))
        XCTAssertNotEqual(baseline, try key(recipe, identity: "updated"))
        XCTAssertNotEqual(baseline, try key(recipe, tls: "changed"))
        XCTAssertThrowsError(try key(recipe, assets: ["../main.obb": hash]))
    }
}
