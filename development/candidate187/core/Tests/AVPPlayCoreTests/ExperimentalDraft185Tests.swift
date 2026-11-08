import XCTest
@testable import AVPPlayCore

final class ExperimentalDraft185Tests: XCTestCase {
    private func fixture(knownEngine: Bool = true) throws -> (URL, LocalProvisionalRecipeStore, LocalProvisionalRecipe) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("draft185-\(UUID())")
        let store = LocalProvisionalRecipeStore(root: root.appendingPathComponent("records"))
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        let record = LocalProvisionalRecipe(apkSHA256: String(repeating: "a", count: 64), apkSize: 100,
            apkPath: root.appendingPathComponent("base.apk").path, title: "Synthetic", package: "com.example.draft185",
            versionName: "1", versionCode: "47", architectures: ["arm64-v8a"],
            nativeLibraries: knownEngine ? ["lib/arm64-v8a/libUE4.so"] : [], assets: [], externalFileReferences: [],
            externalFiles: [.init(path: root.appendingPathComponent("unknown.pak").path, size: 12, sha256: String(repeating: "b", count: 64))],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: store.root.appendingPathComponent(record.id + ".json"))
        return (root, store, record)
    }
    func testIncompleteIdentityAndUnknownEngineCanBeSavedAndReopenedWithoutRuntime() throws {
        let (root, store, original) = try fixture(knownEngine: false)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(original.experimentalReviewState185, "Análise provisória salva")
        let saved = try store.saveExperimentalDraft(appID: "88", provenance: "", for: original.id)
        XCTAssertEqual(saved.experimentalDraft185?.appID, "88")
        XCTAssertEqual(saved.experimentalDraft185?.provenance, "")
        XCTAssertNil(saved.experimentalTarget); XCTAssertNil(saved.experimentalRecipe)
        XCTAssertTrue(saved.experimentalReviewState185.contains("validação pendente"))
        XCTAssertEqual(try LocalProvisionalRecipeStore(root: store.root).loadAll(), [saved])
    }
    func testValidIdentityCreatesPersistentPendingRecipeButDoesNotApproveUnknownAssets() throws {
        let (root, store, original) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let saved = try store.saveExperimentalDraft(appID: "123456", provenance: "Synthetic documented source", for: original.id)
        XCTAssertEqual(saved.experimentalTarget?.target, "x123456")
        XCTAssertEqual(saved.experimentalTarget?.toolchain, "850-cc2856c")
        XCTAssertEqual(saved.experimentalTarget?.minCommit, "cc2856c")
        XCTAssertEqual(saved.externalFiles, original.externalFiles)
        XCTAssertEqual(saved.apkSHA256, original.apkSHA256)
        XCTAssertNil(saved.experimentalRecipe)
        XCTAssertTrue(saved.experimentalBlockers.contains { $0.contains("Arquivo externo") })
        XCTAssertEqual(try store.loadAll(), [saved])
    }
    func testEditingExistingIdentityPreservesHashDatesAndAssociations() throws {
        let (root, store, original) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try store.saveExperimentalDraft(appID: "123456", provenance: "First source", for: original.id)
        let updated = try store.saveExperimentalDraft(appID: "654321", provenance: "Updated source", for: original.id)
        XCTAssertEqual(updated.experimentalTarget?.appID, "654321")
        XCTAssertEqual(updated.experimentalTarget?.provenance, "Updated source")
        XCTAssertEqual(updated.externalFiles, original.externalFiles)
        XCTAssertEqual(updated.createdAt, original.createdAt)
        XCTAssertEqual(updated.apkPath, original.apkPath)
        XCTAssertEqual(try store.loadAll().count, 1)
        let file = store.root.appendingPathComponent(original.id + ".json")
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        XCTAssertEqual(try store.saveExperimentalDraft(appID: "654321", provenance: "Updated source", for: original.id), updated)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date, date)
    }
    func testPartialEditCannotReuseOldCompleteIdentityAsBuildAuthority() throws {
        let (root, store, original) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try store.saveExperimentalDraft(appID: "123456", provenance: "Source", for: original.id)
        let partial = try store.saveExperimentalDraft(appID: "", provenance: "", for: original.id)
        XCTAssertNil(partial.experimentalRecipe)
        XCTAssertTrue(partial.experimentalBlockers.contains { $0.contains("rascunho") })
        XCTAssertEqual(try store.loadAll().first?.experimentalDraft185?.appID, "")
    }
    func testSavingNeverAllowsHistoricalRuntimeAndUnsafeTextDoesNotOverwrite() throws {
        let (root, store, original) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let before = try Data(contentsOf: store.root.appendingPathComponent(original.id + ".json"))
        XCTAssertThrowsError(try store.saveExperimentalDraft(appID: "123456", provenance: "Source", runtime: .klepton824, for: original.id))
        XCTAssertThrowsError(try store.saveExperimentalDraft(appID: "123456", provenance: "bad\u{0000}text", for: original.id))
        XCTAssertEqual(try Data(contentsOf: store.root.appendingPathComponent(original.id + ".json")), before)
    }
}
