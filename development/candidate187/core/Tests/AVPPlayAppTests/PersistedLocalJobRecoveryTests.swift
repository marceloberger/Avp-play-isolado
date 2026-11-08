import XCTest
@testable import AVPPlayApp
@testable import AVPPlayCore

final class PersistedLocalJobRecoveryTests: XCTestCase {
    @MainActor
    func testFourPersistedCommunityJobsAppearAsManualPendingWithoutStarting() throws {
        let (initial, root) = try fixture()
        let recipe = communityRecipe()
        let jobs = try saveFourBuildOnlyJobs(recipe: recipe, store: initial.paths.jobs)
        let prepared = root.appendingPathComponent("toolchains/750-900daf8/x6072194326150034/.qi-prepared")
        let preparedContents = "preserved-fixture-marker"
        try FileManager.default.createDirectory(at: prepared.deletingLastPathComponent(), withIntermediateDirectories: true)
        try preparedContents.write(to: prepared, atomically: true, encoding: .utf8)
        let before = try Dictionary(uniqueKeysWithValues: jobs.map { job in
            (job.id, try Data(contentsOf: initial.paths.jobs.directory.appendingPathComponent("\(job.id).json")))
        })

        let reopened = AppModel(paths: initial.paths, runJobsAutomatically: true, resumeDevices: { [] })
        reopened.reloadJobs()

        XCTAssertEqual(reopened.jobs.count, 4)
        XCTAssertTrue(reopened.queued.isEmpty, "persisted waiting Jobs must not auto-run on launch")
        XCTAssertNil(reopened.runningJob)
        for job in reopened.jobs {
            XCTAssertEqual(reopened.phase(of: job), .pending)
            XCTAssertTrue(reopened.queueExplanation(for: job)?.contains("não iniciam automaticamente") == true)
        }
        for job in jobs {
            XCTAssertEqual(try Data(contentsOf: initial.paths.jobs.directory.appendingPathComponent("\(job.id).json")), before[job.id])
        }
        XCTAssertEqual(try String(contentsOf: prepared, encoding: .utf8), preparedContents,
                       "recovery must not modify an already prepared tree")
    }

    @MainActor
    func testSelectingOnePersistedBuildOnlyQueuesOnlyThatOriginalJob() async throws {
        let (model, _) = try fixture()
        let jobs = try saveFourBuildOnlyJobs(recipe: communityRecipe(), store: model.paths.jobs)
        model.reloadJobs()
        let selected = try XCTUnwrap(model.jobs.first)
        let second = try XCTUnwrap(model.jobs.first { $0.id != selected.id })

        model.resume(selected)
        try await waitForResume(model, selected.id)
        XCTAssertEqual(model.queued, [selected.id])
        XCTAssertTrue(model.queueExplanation(for: second)?.contains("Outro Job da mesma variante") == true)
        XCTAssertEqual(model.runningJob, nil, "test fixture disables execution; no compile is permitted")
        XCTAssertEqual(try model.paths.jobs.load(selected.id).attempts, 0)
        XCTAssertEqual(model.jobs.count, 4)

        model.resume(second)
        try await waitForResume(model, second.id)
        XCTAssertEqual(model.queued, [selected.id], "only one duplicate operation may be queued")
        XCTAssertTrue(model.resumeMessages[second.id]?.contains("Outro Job") == true)
        XCTAssertEqual(Set(model.paths.jobs.all().map(\.id)), Set(jobs.map(\.id)))
    }

    @MainActor
    func testBuildOnlyClickFindsRecoveredJobInsteadOfCreatingDuplicate() throws {
        let (model, _) = try fixture()
        let jobs = try saveFourBuildOnlyJobs(recipe: communityRecipe(), store: model.paths.jobs)
        model.reloadJobs()
        let game = model.localGame(for: communityRecipe())

        model.xcodeProblem = "Synthetic missing Xcode: discovery must still work"
        model.buildLocalAPKVariant(game, id: "recovered-variant")

        XCTAssertEqual(model.jobs.count, 4)
        XCTAssertEqual(model.paths.jobs.all().count, 4)
        XCTAssertEqual(model.section, .jobs)
        XCTAssertTrue(jobs.contains { $0.id == model.selectedJob })
        XCTAssertTrue(model.notice?.contains("nenhum duplicado") == true)
        XCTAssertTrue(model.queued.isEmpty)
    }

    @MainActor
    func testHistoricalJobsAreVisibleAndBlockedWithoutChangingJSONOrLogs() async throws {
        let (model, _) = try fixture()
        let jobs = try saveFourBuildOnlyJobs(recipe: communityRecipe(), store: model.paths.jobs)
        var original: [URL: Data] = [:]
        for (index, saved) in jobs.enumerated() {
            var job = saved
            job.toolchainCommit = index.isMultiple(of: 2) ? "900daf8" : "a61188d"
            job.request.toolchain = "/fixture/historical/" + job.toolchainCommit
            try model.paths.jobs.save(job)
            let json = model.paths.jobs.directory.appendingPathComponent(job.id + ".json")
            let log = model.paths.jobs.directory.appendingPathComponent(job.id + ".log")
            try Data("historical log preserved".utf8).write(to: log)
            original[json] = try Data(contentsOf: json)
            original[log] = try Data(contentsOf: log)
        }
        model.reloadJobs()
        XCTAssertEqual(model.jobs.count, 4)
        for job in model.jobs {
            model.resume(job)
            try await waitForResume(model, job.id)
            XCTAssertTrue(model.resumeMessages[job.id]?.contains("850") == true)
        }
        XCTAssertTrue(model.queued.isEmpty)
        XCTAssertNil(model.runningJob)
        for (url, bytes) in original {
            XCTAssertEqual(try Data(contentsOf: url), bytes, "Blocked historical Jobs and logs must remain byte-identical")
        }
        XCTAssertEqual(Set(model.paths.jobs.all().map(\.id)), Set(jobs.map(\.id)))
    }

    @MainActor
    func testResumeValidatesPersistedJobInsteadOfStaleScreenCopy() async throws {
        let (model, _) = try fixture()
        let stale = try XCTUnwrap(saveFourBuildOnlyJobs(recipe: communityRecipe(), store: model.paths.jobs).first)
        var stored = stale
        stored.toolchainCommit = "a61188d"
        stored.request.toolchain = "/fixture/historical/824"
        try model.paths.jobs.save(stored)
        let json = model.paths.jobs.directory.appendingPathComponent(stored.id + ".json")
        let before = try Data(contentsOf: json)
        model.resume(stale)
        try await waitForResume(model, stale.id)
        XCTAssertTrue(model.queued.isEmpty)
        XCTAssertTrue(model.resumeMessages[stale.id]?.contains("850") == true)
        XCTAssertEqual(try Data(contentsOf: json), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.paths.jobs.directory.appendingPathComponent(stored.id + ".log").path))
    }

    @MainActor
    private func fixture() throws -> (AppModel, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("persisted-job-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let recipes = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("recipes")
        let runtime = try Verified850Fixture.source()
        let paths = Paths(recipes: recipes, store: ContentStore(root: root.appendingPathComponent("store")),
            jobs: JobStore(directory: root.appendingPathComponent("jobs")),
            packager: ToolchainPackager(root: runtime.root.deletingLastPathComponent()))
        return (AppModel(paths: paths, runJobsAutomatically: false, resumeDevices: { [] }), root)
    }

    private func saveFourBuildOnlyJobs(recipe: Recipe, store: JobStore) throws -> [Job] {
        try ["aaaa", "bbbb", "cccc", "dddd"].enumerated().map { index, suffix in
            let runtime = try Verified850Fixture.source()
            var request = InstallRequest(toolchain: runtime.root.path)
            request.localAPKVariantID = "recovered-variant"
            request.localVariantStorePath = "/fixture/variants"
            request.localWorkspaceRoot = "/fixture/workspaces"
            let job = Job(recipe: recipe, request: request, steps: [.buildOnly], toolchainCommit: "cc2856c",
                          now: Date(timeIntervalSince1970: 1_800_000_000 + Double(index)), suffix: suffix)
            try store.save(job)
            return job
        }
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

    @MainActor
    private func waitForResume(_ model: AppModel, _ id: String) async throws {
        for _ in 0..<100 {
            if !model.resumingJobIDs.contains(id) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("manual start preflight did not finish")
    }
}
