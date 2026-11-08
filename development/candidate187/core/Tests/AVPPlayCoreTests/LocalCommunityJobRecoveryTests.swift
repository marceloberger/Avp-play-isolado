import XCTest
@testable import AVPPlayCore

final class LocalCommunityJobRecoveryTests: XCTestCase {
    func testPersistedCommunityBuildOnlyJobLoadsWithoutRewritingIt() throws {
        let root = try temporaryRoot()
        let store = JobStore(directory: root.appendingPathComponent("jobs"))
        let job = communityBuildJob(suffix: "reco")
        try store.save(job)
        let url = store.directory.appendingPathComponent("\(job.id).json")
        let original = try Data(contentsOf: url)

        let reopened = JobStore(directory: store.directory)
        let visible = try XCTUnwrap(reopened.all().first)
        XCTAssertEqual(visible.id, job.id)
        XCTAssertEqual(visible.state, .waiting)
        XCTAssertEqual(visible.attempts, 0)
        XCTAssertEqual(visible.request.localAPKVariantID, "community-variant")
        XCTAssertEqual(visible.steps, [.buildOnly])
        XCTAssertEqual(try reopened.load(job.id).recipe.files.first?.id, "local-community")
        XCTAssertEqual(try Data(contentsOf: url), original, "loading a recovered Job must not mutate its JSON")
    }

    func testLocalCommunityValidationExceptionIsNarrowAndJobOnly() throws {
        var recipe = communityRecipe()
        XCTAssertThrowsError(try recipe.validate(), "synthetic local recipes remain invalid in the distributable recipe store")
        XCTAssertNoThrow(try recipe.validateForJob())

        recipe.files[0].localName = "../outside.apk"
        XCTAssertThrowsError(try recipe.validateForJob(), "ordinary path validation still applies")

        recipe = communityRecipe()
        recipe.toolchain.target = "unsafe/target"
        XCTAssertThrowsError(try recipe.validateForJob(), "the generic target must still match the store ID safely")
    }

    func testLocalCommunityBuildReceiptAcceptsOnlyValidatedJobRecipe() throws {
        let fixture = try Verified850Fixture.build(root: temporaryRoot(), recipe: communityRecipe())
        let job = fixture.job
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let jobData = try encoder.encode(job)
        let artifact = fixture.artifact

        XCTAssertThrowsError(try job.recipe.validate(), "the distributable-recipe validator must reject the synthetic file ID")
        let receipt = try LocalBuildReceipt(jobData: jobData,
            logData: Data(fixture.log.utf8), artifact: artifact)
        XCTAssertEqual(try receipt.job().recipe.files.first?.id, "local-community")
        XCTAssertEqual(try receipt.job().id, job.id)

        var malformed = job
        malformed.recipe.files[0].id = "local-community-alternate"
        XCTAssertThrowsError(try LocalBuildReceipt(jobData: encoder.encode(malformed),
            logData: Data(fixture.log.utf8), artifact: artifact),
            "receipt recovery must not accept arbitrary nonnumeric file IDs")
    }

    func testOfficialRecipeValidationRemainsStrictForSyntheticIDs() throws {
        var official = try ResumeReuseTests().recipe()
        XCTAssertNoThrow(try official.validate())
        XCTAssertNoThrow(try official.validateForJob())
        official.files[0].id = "local-community"
        XCTAssertThrowsError(try official.validate())
        XCTAssertThrowsError(try official.validateForJob(),
            "the community exception must not apply to official recipes")
    }

    func testUnrelatedSyntheticFileIDRemainsRejectedByJobStore() throws {
        let root = try temporaryRoot()
        let store = JobStore(directory: root.appendingPathComponent("jobs"))
        var recipe = communityRecipe()
        recipe.files[0].id = "arbitrary-local-id"
        let job = Job(recipe: recipe, request: InstallRequest(toolchain: "/fixture"),
                      steps: [.buildOnly], toolchainCommit: "900daf8", suffix: "bad1")
        try store.save(job)

        XCTAssertThrowsError(try store.load(job.id))
        XCTAssertTrue(store.all().isEmpty)
    }

    func testHistoricalRunnerRejectsBuildsWithoutChangingPersistedJobOrLog() async throws {
        let root = try temporaryRoot(), store = JobStore(directory: root.appendingPathComponent("jobs"))
        for commit in ["900daf8", "a61188d"] {
            var job = communityBuildJob(suffix: commit)
            job.toolchainCommit = commit
            try store.save(job)
            let json = store.directory.appendingPathComponent(job.id + ".json")
            let log = store.directory.appendingPathComponent(job.id + ".log")
            try Data("preserved historical log".utf8).write(to: log)
            let before = try Data(contentsOf: json), logBefore = try Data(contentsOf: log)
            do {
                _ = try await JobRunner(store: store).run(job, currentToolchain: commit) { _, _ in
                    XCTFail("A historical runtime must never execute a step")
                }
                XCTFail("850 must be mandatory")
            } catch { XCTAssertTrue(String(describing: error).contains("850")) }
            XCTAssertEqual(try Data(contentsOf: json), before)
            XCTAssertEqual(try Data(contentsOf: log), logBefore)
            XCTAssertEqual(try store.load(job.id).toolchainCommit, commit)
        }
    }

    func testTerminalHistoricalJobReportsStateWithoutRuntimeOrMutation() async throws {
        let root = try temporaryRoot(), store = JobStore(directory: root.appendingPathComponent("jobs"))
        for state in [Job.State.cancelled, .finished] {
            var job = communityBuildJob(suffix: state.rawValue)
            job.state = state
            try store.save(job)
            let json = store.directory.appendingPathComponent(job.id + ".json")
            let before = try Data(contentsOf: json)
            do {
                _ = try await JobRunner(store: store).run(job, currentToolchain: "missing") { _, _ in XCTFail() }
                XCTFail("Terminal Job cannot run")
            } catch {
                XCTAssertEqual(error as? JobError, state == .cancelled ? .cancelled(job.id) : .alreadyFinished(job.id))
            }
            XCTAssertEqual(try Data(contentsOf: json), before)
        }
    }

    private func communityBuildJob(suffix: String) -> Job {
        var request = InstallRequest(toolchain: "/fixture/toolchain")
        request.localAPKVariantID = "community-variant"
        request.localVariantStorePath = "/fixture/variants"
        request.localWorkspaceRoot = "/fixture/workspaces"
        return Job(recipe: communityRecipe(), request: request, steps: [.buildOnly],
                   toolchainCommit: "900daf8", suffix: suffix)
    }

    private func communityRecipe() -> Recipe {
        Recipe(schema: 1, id: "community-6072194326150034", title: "Zero Caliber 2",
               package: "com.XrealGames.Zc15", versionName: "2.0.1173-S-80237", versionCode: 1173,
               store: .init(appId: nil), toolchain: .init(target: "x6072194326150034", minCommit: "900daf8"),
               files: [.init(name: "base.apk", role: "apk", id: "local-community", required: true,
                             localName: "x6072194326150034.apk")], addons: nil,
               status: .init(playability: "untested", download: "local", notes: nil),
               icon: .init(steamAppId: nil, metaAppId: "6072194326150034"), trees: nil)
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("local-community-jobs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}
