import XCTest
@testable import AVPPlayCore

final class CandidateStageTransferTests: XCTestCase {
    private func fixture() throws -> (URL, Recipe, Toolchain, [(file: RecipeFile, url: URL, size: Int64)]) {
        let helper = InstallationHardeningTests(), root = try helper.scratch()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        var recipe = try helper.recipe()
        recipe.files = recipe.files.filter { $0.role == "apk" }
        recipe.trees = nil; recipe.assetFiles = nil
        let apk = root.appendingPathComponent("library/selected.apk")
        try helper.write("selected APK", apk)
        recipe.files[0].sha256 = try Hashing.sha256(of: apk)
        recipe.files[0].size = ContentStore.fileSize(apk)
        try helper.write("fixture", root.appendingPathComponent("shared/visionos/run.sh"))
        let tc = try Toolchain(root: root.appendingPathComponent("shared"))
        let tree = root.appendingPathComponent("build-only/" + KleptonRecipeCompatibility.resolve(recipe).toolchain.target)
        try helper.write("<manifest package=\"\(recipe.package)\"/>", tree.appendingPathComponent("AndroidManifest.xml"))
        try helper.write("versionInfo:\n  versionCode: \(recipe.versionCode)\n", tree.appendingPathComponent("apktool.yml"))
        try helper.write("selected asset", tree.appendingPathComponent("assets/selected.bin"))
        return (root, recipe, tc, [(recipe.files[0], apk, try XCTUnwrap(ContentStore.fileSize(apk)))])
    }
    private func entries(_ f: (URL, Recipe, Toolchain, [(file: RecipeFile, url: URL, size: Int64)])) throws -> [InstallationContent.Entry] {
        try InstallationContent.stageEntries(recipe: f.1, local: f.3, toolchain: f.2,
            metadataWorkspace: f.0.appendingPathComponent("build-only"))
    }
    func testMissingStageAPKFailsBeforeTransfer() throws {
        let f = try fixture()
        XCTAssertThrowsError(try InstallationContent.stageEntries(recipe: f.1, local: [], toolchain: f.2,
            metadataWorkspace: f.0.appendingPathComponent("build-only")))
        try FileManager.default.removeItem(at: f.3[0].url)
        XCTAssertThrowsError(try entries(f))
    }
    func testPreparationUsesRegisteredAPKAndBuildOnlyMetadataWithoutSharedAPK() throws {
        let f = try fixture(), manifest = try entries(f)
        let apk = try XCTUnwrap(manifest.first { $0.destination.hasSuffix(".apk") })
        XCTAssertEqual(apk.source, f.3[0].url)
        XCTAssertEqual(apk.destination, StagePlan.destination(for: f.1.files[0]))
        XCTAssertEqual(manifest.count, 4)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.2.root.appendingPathComponent(f.1.files[0].localName!).path))
        XCTAssertTrue(manifest.contains { $0.destination.contains("/assets/selected.bin") })
    }
    func testBuildOnlyReuseStageContinuationPreservesFrozenPathsAndJob() throws {
        let f = try fixture()
        var request = InstallRequest(toolchain: f.2.root.path)
        request.localAPKVariantID = "synthetic"; request.bundleId = "test.target.game"
        request.device = "fixture-device"; request.reuseBuildOnly = true
        request.preservedBuildBundleID = "test.original.target.game"
        request.localVariantStorePath = "/fixture/candidate/variants"
        request.localWorkspaceRoot = "/fixture/candidate/build-only"
        var installed = Job(recipe: f.1, request: request, steps: [.fetch, .build], toolchainCommit: "cc2856c")
        installed.completed = [.fetch, .build]; installed.state = .finished
        let before = installed
        let continuation = try AutomaticLocalInstall.stageContinuation(from: installed)
        XCTAssertEqual(installed, before)
        XCTAssertNotEqual(continuation.id, installed.id)
        XCTAssertEqual(continuation.steps, [.stage])
        XCTAssertEqual(continuation.request.localVariantStorePath, request.localVariantStorePath)
        XCTAssertEqual(continuation.request.localWorkspaceRoot, request.localWorkspaceRoot)
        XCTAssertEqual(continuation.request.bundleId, request.bundleId)
        XCTAssertEqual(continuation.request.preservedBuildBundleID, request.preservedBuildBundleID)
        XCTAssertEqual(continuation.request.reuseBuildOnly, true)
        XCTAssertEqual(continuation.request.resign, false)
        installed.completed = [.fetch]
        XCTAssertThrowsError(try AutomaticLocalInstall.stageContinuation(from: installed))
    }
    func testIncompleteTransferFailsAndResumeCopiesOnlyPendingWithoutBuildOrSign() async throws {
        let f = try fixture(), manifest = try entries(f)
        let remote = InstallationHardeningTests.Remote()
        let brokenPath = try XCTUnwrap(manifest.last?.destination)
        remote.failingPath = brokenPath
        let jobs = JobStore(directory: f.0.appendingPathComponent("jobs"))
        let job = Job(recipe: f.1, request: InstallRequest(toolchain: try Verified850Fixture.source().root.path), steps: [.stage], toolchainCommit: "cc2856c")
        let receipt = f.0.appendingPathComponent("receipt.json")
        try jobs.save(job)
        do {
            _ = try await JobRunner(store: jobs).run(job, currentToolchain: "cc2856c", log: { _ in }) { step, _ in
                XCTAssertEqual(step, .stage)
                try InstallationContent.sync(manifest, container: remote.container, receipts: receipt)
            }
            XCTFail("Incomplete transfer must fail")
        } catch {}
        let failed = try jobs.load(job.id)
        XCTAssertEqual(failed.state, .failed); XCTAssertEqual(failed.remaining, [.stage])
        let uploaded = remote.uploads
        remote.failingPath = nil
        let done = try await JobRunner(store: jobs).run(failed, currentToolchain: "cc2856c", log: { _ in }) { step, _ in
            XCTAssertEqual(step, .stage)
            try InstallationContent.sync(manifest, container: remote.container, receipts: receipt)
        }
        XCTAssertEqual(done.state, .finished)
        XCTAssertEqual(remote.uploads.count, uploaded.count + 1)
        for entry in manifest { XCTAssertEqual(remote.files[entry.destination], try Data(contentsOf: entry.source)) }
    }
    func testSuccessfulCopyWithoutCorrectRemoteBytesCannotConfirmStage() throws {
        let f = try fixture(), remote = InstallationHardeningTests.Remote()
        remote.broken = true
        XCTAssertThrowsError(try InstallationContent.sync(entries(f), container: remote.container,
            receipts: f.0.appendingPathComponent("receipt.json")))
    }
    func testSelectedOBBAndOptionalAssetAreInVerificationManifest() throws {
        let f = try fixture(), helper = InstallationHardeningTests()
        let obb = f.0.appendingPathComponent("selected.obb")
        try helper.write("required OBB", obb)
        let destination = "Documents/android-files/Android/obb/\(f.1.package)/selected.obb"
        let associated = try InstallationContent.entry(source: obb, destination: destination)
        let manifest = try InstallationContent.stageEntries(recipe: f.1, local: f.3, toolchain: f.2,
            metadataWorkspace: f.0.appendingPathComponent("build-only"), associated: [associated])
        XCTAssertTrue(manifest.contains(associated))
        XCTAssertTrue(manifest.contains { $0.destination.contains("/assets/selected.bin") })
        let remote = InstallationHardeningTests.Remote()
        try InstallationContent.sync(manifest, container: remote.container, receipts: f.0.appendingPathComponent("receipt.json"))
        XCTAssertEqual(remote.files[destination], try Data(contentsOf: obb))
    }
}
