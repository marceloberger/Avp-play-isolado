import XCTest
@testable import AVPPlayCore

final class ExperimentalRuntime183Tests: XCTestCase {
    private var apk: ApkUnpacker.Inspection {
        .init(package: "com.wanadev.propagation_ph", versionCode: "47", versionName: "1.3.1",
              architectures: ["arm64-v8a"], files: 1, nativeLibraries: ["lib/arm64-v8a/libUE4.so"])
    }
    private func record() -> LocalProvisionalRecipe {
        .init(apkSHA256: String(repeating: "a", count: 64), apkSize: 100,
              apkPath: "/tmp/base.apk", title: "Paradise", package: "com.wanadev.propagation_ph",
              versionName: "1.3.1", versionCode: "47", architectures: ["arm64-v8a"],
              nativeLibraries: ["lib/arm64-v8a/libUE4.so"], assets: [], externalFileReferences: [],
              externalFiles: [], createdAt: Date(timeIntervalSince1970: 0))
    }
    private func target() throws -> LocalExperimentalTarget {
        try .init(appID: "8826022237415280", provenance: "https://www.meta.com/experiences/propagation-paradise-hotel/8826022237415280/",
                  analysis: LocalGenericTargetAnalysis.inspect(apk))
    }
    func testNewRecipeProfileCommitAndJobValidationAgree() throws {
        var r = record(); r.experimentalTarget = try target()
        let recipe = try XCTUnwrap(r.experimentalRecipe)
        XCTAssertEqual(recipe.toolchain.minCommit, "cc2856c")
        XCTAssertEqual(recipe.localExperimental?.toolchain, "850-cc2856c")
        XCTAssertEqual(recipe.toolchain.target, "x8826022237415280")
        XCTAssertEqual(recipe.status.playability, "untested")
        XCTAssertNoThrow(try recipe.validateForJob())
        XCTAssertNoThrow(try RecipeValidation176.validate(apk, recipe: recipe, version: 850))
        XCTAssertThrowsError(try RecipeValidation176.validate(apk, recipe: recipe, version: 824))
        XCTAssertThrowsError(try recipe.validate())
    }
    func testHistoricalTargetDecodesWithoutMigrationButCannotBeSelected() throws {
        let encoder = JSONEncoder()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(target())) as? [String: Any])
        object["toolchain"] = "824-a61188d"; object["minCommit"] = "a61188d"
        let bytes = try JSONSerialization.data(withJSONObject: object)
        let old = try JSONDecoder().decode(LocalExperimentalTarget.self, from: bytes)
        XCTAssertEqual(old.toolchain, "824-a61188d")
        var r = record(); r.experimentalTarget = old
        let recipe = try XCTUnwrap(r.experimentalRecipe)
        XCTAssertEqual(recipe.toolchain.minCommit, "a61188d")
        XCTAssertNoThrow(try recipe.validateForJob(), "historical Jobs remain readable")
        XCTAssertThrowsError(try RecipeValidation176.validate(apk, recipe: recipe, version: 850))
        XCTAssertThrowsError(try LocalExperimentalTarget(appID: old.appID, provenance: old.provenance,
            analysis: LocalGenericTargetAnalysis.inspect(apk), runtime: .klepton824))
        XCTAssertEqual(ExperimentalRuntime183.permitted, [.klepton850])
    }
    func testMismatchedAndUnknownProfilesFailClosed() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(target())) as? [String: Any])
        object["minCommit"] = "a61188d"
        var r = record()
        r.experimentalTarget = try JSONDecoder().decode(LocalExperimentalTarget.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(r.experimentalRecipe)
        object["toolchain"] = "999-unverified"
        r.experimentalTarget = try JSONDecoder().decode(LocalExperimentalTarget.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(r.experimentalRecipe)
    }
    func testMissingAndForgedRuntimeNeverBecomeAvailable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let analysis = LocalGenericTargetAnalysis.inspect(apk)
        XCTAssertThrowsError(try ExperimentalRuntime183.klepton850.verifiedSource(at: root, analysis: analysis))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"version":850,"commit":"cc2856c"}"#.utf8).write(to: root.appendingPathComponent("toolchain.json"))
        XCTAssertThrowsError(try ExperimentalRuntime183.klepton850.verifiedSource(at: root, analysis: analysis))
        XCTAssertThrowsError(try ExperimentalRuntime183.klepton824.verifiedSource(at: root, analysis: analysis))
    }
    func testCurrentAnalysisIgnoresStalePersisted824ReviewWithoutWritingIt() throws {
        var r = record()
        r.identification169 = .init(rules: "824-a61188d/recipes169-v1",
            decisions: [.init(field: "entrypoint", value: "wrong", evidence: "inferred", source: "old")], diagnostics: [])
        let before = try JSONEncoder().encode(r)
        XCTAssertEqual(r.analysis169.rules, ExperimentalRuntime183.klepton850.rules)
        XCTAssertEqual(r.analysis169.decisions.first { $0.field == "entrypoint" }?.value, "libUE4")
        XCTAssertEqual(r.identification169?.rules, "824-a61188d/recipes169-v1")
        XCTAssertEqual(try JSONDecoder().decode(LocalProvisionalRecipe.self, from: before), r)
    }
    func testIdentityAndUnmappedFilesStillBlock() throws {
        var r = record()
        XCTAssertNil(r.experimentalRecipe)
        r.experimentalTarget = try target()
        r.externalFiles = [.init(path: "/tmp/main.47.com.wanadev.propagation_ph.obb", size: 100,
            sha256: String(repeating: "b", count: 64))]
        XCTAssertNil(r.experimentalRecipe)
        XCTAssertFalse(r.experimentalBlockers.isEmpty)
        XCTAssertEqual(r.genericOBBDirectory, "android-files/Android/obb/com.wanadev.propagation_ph")
    }
    func testActual850SourceAndTLSContractReadOnly() throws {
        guard let path = ProcessInfo.processInfo.environment["AVP183_READONLY_RUNTIME"] else { throw XCTSkip("Explicit read-only source path required") }
        let runtime = try ExperimentalRuntime183.klepton850.verifiedSource(at: URL(fileURLWithPath: path),
            analysis: LocalGenericTargetAnalysis.inspect(apk))
        XCTAssertEqual(runtime.version(), 850); XCTAssertEqual(runtime.commit(), "cc2856c")
    }
}
