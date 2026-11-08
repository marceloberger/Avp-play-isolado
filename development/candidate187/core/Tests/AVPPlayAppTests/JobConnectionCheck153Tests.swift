import XCTest
import Combine
import SwiftUI
import AppKit
@testable import AVPPlayApp
@testable import AVPPlayCore

final class JobConnectionCheck153Tests: XCTestCase {
    final class Gate: @unchecked Sendable {
        let entered = XCTestExpectation(description: "query entered")
        let release = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var count = 0
        func query() -> String {
            lock.lock(); count += 1; lock.unlock()
            entered.fulfill(); _ = release.wait(timeout: .now() + 5)
            return "Conexão verificada. Stage continua pendente."
        }
    }
    @MainActor
    func fixture(query: @escaping @Sendable (Job, ContentStore) throws -> String) throws -> (AppModel, Job) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("check153-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let paths = Paths(recipes: nil, store: ContentStore(root: root.appendingPathComponent("store")),
            jobs: JobStore(directory: root.appendingPathComponent("jobs")), packager: ToolchainPackager(root: root.appendingPathComponent("toolchains")))
        let model = AppModel(paths: paths, runJobsAutomatically: false, resumeDevices: { XCTFail("Check Again must not call Resume"); return [] }, jobConnectionQuery: query)
        let recipe = try JSONDecoder().decode(Recipe.self, from: Data(#"{"schema":1,"id":"fixture153","title":"Fixture","package":"test.fixture","versionName":"1","status":{"download":"local","playability":"untested"},"versionCode":1,"store":{},"toolchain":{"target":"fixture","minCommit":"fixture"},"files":[]}"#.utf8))
        var job = Job(recipe: recipe, request: InstallRequest(toolchain: "/fixture"), steps: [.fetch, .build, .stage], toolchainCommit: "fixture")
        job.state = .failed; job.completed = [.fetch, .build]; job.attempts = 4; job.failureKind = .device
        try paths.jobs.save(job); model.jobs = [job]
        return (model, job)
    }
    @MainActor
    func settle(_ model: AppModel) async throws {
        for _ in 0..<200 {
            if model.checkingConnectionJobID == nil { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Check did not settle")
    }
    @MainActor
    func testButtonActionReachesQueryAndPublishesCheckingThenConnected() async throws {
        let gate = Gate(); defer { gate.release.signal() }
        let (model, job) = try fixture { _, _ in gate.query() }
        let view = JobConnectionCheckView(model: model, job: job)
        var states: [JobConnectionCheckState] = []
        let subscription = model.$jobConnectionChecks.sink { if let state = $0[job.id] { states.append(state) } }
        view.checkAgain() // The same action passed directly to SwiftUI Button.
        XCTAssertEqual(model.jobConnectionChecks[job.id], .checking)
        XCTAssertTrue(model.connectionCheckBlocked)
        await fulfillment(of: [gate.entered], timeout: 2)
        gate.release.signal(); try await settle(model)
        XCTAssertEqual(states, [.checking, .passed("Conexão verificada. Stage continua pendente.")])
        withExtendedLifetime(subscription) {}
    }
    @MainActor
    func testDisconnectedShowsReasonAndAllowsAnotherAttempt() async throws {
        let (model, job) = try fixture { _, _ in throw DeviceError.noDevice }
        JobConnectionCheckView(model: model, job: job).checkAgain(); try await settle(model)
        guard case .failed(let message) = model.jobConnectionChecks[job.id] else { return XCTFail() }
        XCTAssertTrue(message.contains("Verificação falhou")); XCTAssertTrue(message.contains("Check Again"))
        XCTAssertFalse(model.connectionCheckBlocked)
    }
    @MainActor
    func testCoreDeviceErrorIsVisibleWithoutClaimingAbsence() async throws {
        let (model, job) = try fixture { _, _ in throw DeviceError.tool("CoreDevice.ActionError error 3 StreamingAction") }
        model.checkJobConnection(job); try await settle(model)
        XCTAssertTrue(model.jobConnectionChecks[job.id]!.message.contains("StreamingAction"))
        XCTAssertFalse(model.jobConnectionChecks[job.id]!.message.contains("Ausência confirmada"))
    }
    @MainActor
    func testSuccessReplacesPreviousErrorAndRepeatedAttemptsRunFreshQueries() async throws {
        let gate = Gate()
        let (model, job) = try fixture { _, _ in
            gate.lock.lock(); gate.count += 1; let n = gate.count; gate.lock.unlock()
            if n == 1 { throw DeviceError.tool("previous failure") }
            return "Connected again"
        }
        model.checkJobConnection(job); try await settle(model)
        guard case .failed = model.jobConnectionChecks[job.id] else { return XCTFail() }
        model.checkJobConnection(job); try await settle(model)
        XCTAssertEqual(model.jobConnectionChecks[job.id], .passed("Connected again"))
        model.checkJobConnection(job); try await settle(model); XCTAssertEqual(gate.count, 3)
    }
    @MainActor
    func testDoubleClickCannotStartConcurrentQueriesOrResume() async throws {
        let gate = Gate(); defer { gate.release.signal() }
        let (model, job) = try fixture { _, _ in gate.query() }
        let before = try Data(contentsOf: model.paths.jobs.directory.appendingPathComponent(job.id + ".json"))
        model.checkJobConnection(job); model.checkJobConnection(job); model.resume(job)
        await fulfillment(of: [gate.entered], timeout: 2)
        XCTAssertEqual(gate.count, 1); XCTAssertTrue(model.queued.isEmpty); XCTAssertTrue(model.resumingJobIDs.isEmpty)
        gate.release.signal(); try await settle(model)
        XCTAssertEqual(try Data(contentsOf: model.paths.jobs.directory.appendingPathComponent(job.id + ".json")), before)
        XCTAssertEqual(try model.paths.jobs.load(job.id).remaining, [.stage]); XCTAssertNil(model.runningJob)
    }
    @MainActor
    func testActiveRefreshJobQueueAndResumeBlockCheckWithFeedback() throws {
        let (model, job) = try fixture { _, _ in XCTFail("Blocked query ran"); return "" }
        model.refreshing = true; model.checkJobConnection(job); model.refreshing = false
        XCTAssertTrue(model.jobConnectionChecks[job.id]!.message.contains("Aguarde"))
        model.runningJob = "other"; model.checkJobConnection(job); model.runningJob = nil
        model.queued = ["other"]; model.checkJobConnection(job); model.queued = []
        model.resumingJobIDs = ["other"]; model.checkJobConnection(job)
        XCTAssertNil(model.checkingConnectionJobID)
    }
    @MainActor
    func testSecondJobAndGlobalRefreshCannotOverlapRunningCheck() async throws {
        let gate = Gate(); defer { gate.release.signal() }
        let (model, job) = try fixture { _, _ in gate.query() }
        var other = job; other.id = "other-job"
        model.checkJobConnection(job)
        model.checkJobConnection(other)
        model.refresh()
        XCTAssertFalse(model.refreshing)
        XCTAssertTrue(model.jobConnectionChecks[other.id]!.message.contains("Aguarde"))
        await fulfillment(of: [gate.entered], timeout: 2)
        gate.release.signal(); try await settle(model)
        XCTAssertEqual(gate.count, 1)
    }
    @MainActor
    func testCheckingAndResultViewsRender() throws {
        let (model, job) = try fixture { _, _ in "unused" }
        for state in [JobConnectionCheckState.checking, .passed("Conexão verificada; Stage pendente"), .failed("StreamingAction: tente novamente")] {
            model.jobConnectionChecks[job.id] = state
            model.checkingConnectionJobID = state == .checking ? job.id : nil
            let view = JobConnectionCheckView(model: model, job: job).padding().frame(width: 650)
            XCTAssertNotNil(ImageRenderer(content: view).cgImage)
        }
    }
}
