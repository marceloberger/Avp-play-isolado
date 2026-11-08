import XCTest
@testable import AVPPlayCore

/// Every device operation is replaced by an in-memory query/transfer fixture.
final class CoreDeviceIdentity152Tests: XCTestCase {
    let bundle = "test.zero-caliber"
    let device = Device(udid: "hardware-udid", name: "Fixture", osVersion: "27", reachable: true,
                        paired: true, developerMode: true, coreDeviceIdentifier: "core-device-uuid")
    static func app(_ bundle: String = "test.zero-caliber", url: String? = "file:///fixture/Game.app/",
                    accessible: Bool = true) -> [String: Any] {
        var value: [String: Any] = ["bundleIdentifier": bundle, "name": "Zero Caliber 2",
            "version": "2.0.1173", "bundleVersion": "1173.750", "containerAccessible": accessible]
        if let url { value["url"] = url }
        return value
    }
    static func response(_ apps: [[String: Any]], outcome: String = "success", device: String = "core-device-uuid",
                         bundle: String = "test.zero-caliber") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["info": ["outcome": outcome], "result": [
            "apps": apps, "deviceIdentifier": device, "matchingBundleIdentifier": bundle]])
    }
    func testQueriesExactBundleOnHardwareUDIDAndPreservesFullIdentity() throws {
        let queries = LockedBox<[[String]]>([])
        let control = DeviceControl(query: { args in
            queries.update { $0.append(args) }
            return try Self.response([Self.app()])
        })
        let app = try control.installedApp(device: device, bundle: bundle, pause: { _ in XCTFail("No retry needed") })
        XCTAssertEqual(queries.get(), [["device", "info", "apps", "--device", device.udid, "--bundle-id", bundle]])
        XCTAssertEqual(app.bundleIdentifier, bundle); XCTAssertEqual(app.bundleVersion, "1173.750")
        XCTAssertEqual(app.url, "file:///fixture/Game.app/"); XCTAssertEqual(app.containerAccessible, true)
    }
    func testEmptySuccessfulListThenCorrectIdentityRetriesReadOnly() throws {
        let count = LockedBox(0)
        let control = DeviceControl(query: { _ in
            count.update { $0 += 1 }
            return try Self.response(count.get() == 1 ? [] : [Self.app()])
        })
        var pauses: [Double] = [], logs: [String] = []
        _ = try control.installedApp(device: device, bundle: bundle, report: { logs.append($0) }, pause: { pauses.append($0) })
        XCTAssertEqual(count.get(), 2); XCTAssertEqual(pauses, [1])
        XCTAssertTrue(logs.contains { $0.contains("apps=0") })
    }
    func testPersistentEmptyIsInconclusiveNotUninstalledAndIsBounded() throws {
        let count = LockedBox(0)
        let control = DeviceControl(query: { _ in count.update { $0 += 1 }; return try Self.response([]) })
        XCTAssertThrowsError(try control.installedApp(device: device, bundle: bundle, pause: { _ in })) { error in
            XCTAssertTrue("\(error)".contains("lista vazia não comprova ausência"))
            XCTAssertEqual(FailureKind.of(error), .device)
        }
        XCTAssertEqual(count.get(), 3)
    }
    func testTimeoutDDIAndStreamingFailureAreRetriedOnlyAsReads() throws {
        for message in ["Operation timed out", "CoreDeviceError 12040: developer disk image", "StreamingAction error 3"] {
            let count = LockedBox(0)
            let control = DeviceControl(query: { args in
                XCTAssertFalse(args.contains("copy")); XCTAssertFalse(args.contains("install"))
                count.update { $0 += 1 }
                if count.get() < 3 { throw DeviceError.tool(message) }
                return try Self.response([Self.app()])
            })
            XCTAssertNoThrow(try control.installedApp(device: device, bundle: bundle, pause: { _ in }))
            XCTAssertEqual(count.get(), 3)
        }
    }
    func testWrongBundleMissingURLNonfileURLAndInaccessibleContainerFailClosed() throws {
        let rows = [Self.app("wrong.bundle"), Self.app(url: nil), Self.app(url: "https://example.invalid/app"),
                    Self.app(accessible: false), ["url": "file:///fixture/Game.app/"]]
        for row in rows {
            let control = DeviceControl(query: { _ in try Self.response([row]) })
            XCTAssertThrowsError(try control.installedApp(device: device, bundle: bundle, attempts: 1, pause: { _ in XCTFail() }))
        }
    }
    func testDuplicateOrPartialExtraRowsCannotBecomeSingleIdentity() throws {
        for rows in [[Self.app(), Self.app()], [Self.app(), [:]]] {
            let control = DeviceControl(query: { _ in try Self.response(rows) })
            XCTAssertThrowsError(try control.installedApp(device: device, bundle: bundle, attempts: 1))
        }
    }
    func testFailedOutcomeMalformedJSONAndWrongDeviceAreRejected() throws {
        let invalid = [Data("{}".utf8), Data("broken".utf8),
            try Self.response([Self.app()], outcome: "failed"),
            try Self.response([Self.app()], device: "another-device"),
            try Self.response([Self.app()], bundle: "another-bundle")]
        for data in invalid {
            let control = DeviceControl(query: { _ in data })
            XCTAssertThrowsError(try control.installedApp(device: device, bundle: bundle, attempts: 1))
        }
    }
    func testCancellationDoesNotRetry() throws {
        let control = DeviceControl(query: { _ in throw CancellationError() })
        XCTAssertThrowsError(try control.installedApp(device: device, bundle: bundle, pause: { _ in XCTFail() })) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }
    func testExactQueryCannotBypassChangedPersistedInstallation() throws {
        let helper = StageResume151Tests(), fixture = try helper.fixture(helper.scratch())
        let before = try Data(contentsOf: fixture.receipt)
        let control = DeviceControl(query: { _ in try Self.response([Self.app(helper.bundle, url: "file:///different/Game.app/")], bundle: helper.bundle) })
        let app = try control.installedApp(device: device, bundle: helper.bundle, attempts: 1)
        XCTAssertThrowsError(try InstallationContent.installationScope(device: helper.device, bundle: helper.bundle,
            apps: [app], scopeFile: fixture.scope, receipts: fixture.receipt))
        XCTAssertEqual(try Data(contentsOf: fixture.receipt), before)
    }
}

final class CommunityAPKStage152Tests: XCTestCase {
    func frozenRecipe() throws -> Recipe {
        let data = Data(#"{"schema":1,"id":"community-6072194326150034","title":"Zero Caliber 2","package":"com.XrealGames.Zc15","versionCode":1173,"versionName":"2.0.1173-S-80237","store":{},"icon":{"metaAppId":"6072194326150034"},"status":{"download":"local","playability":"untested"},"toolchain":{"target":"x6072194326150034","minCommit":"900daf8"},"files":[{"name":"base.apk","role":"apk","id":"local-community","required":true,"localName":"x6072194326150034.apk"}]}"#.utf8)
        return try JSONDecoder().decode(Recipe.self, from: data)
    }
    func testFrozenCommunityRecipeWithoutDestStillStagesCompleteAPKAtRuntimePath() throws {
        let recipe = try frozenRecipe(), apk = try XCTUnwrap(recipe.files.first)
        XCTAssertNil(apk.dest)
        XCTAssertEqual(StagePlan.destination(for: apk), "Documents/x6072194326150034.apk")
        let plan = StagePlan.plan(local: [(apk, URL(fileURLWithPath: "/fixture/selected-hash.apk"), 83_919_960)], remote: [:])
        XCTAssertEqual(plan.count, 1); XCTAssertEqual(plan[0].size, 83_919_960)
        XCTAssertEqual(plan[0].destination, "Documents/x6072194326150034.apk")
        XCTAssertNil(recipe.files[0].dest, "Do not rewrite frozen Jobs")
    }
    func testOnlyAPKDefaultsToDocumentsAndExplicitResolvedAliasesRemainUnchanged() throws {
        var file = try XCTUnwrap(frozenRecipe().files.first)
        file.localName = "re4.apk"
        XCTAssertEqual(StagePlan.destination(for: file), "Documents/re4.apk")
        file.dest = "explicit"; XCTAssertEqual(StagePlan.destination(for: file), "Documents/explicit/re4.apk")
        file.dest = nil; file.role = "optional"
        XCTAssertNil(StagePlan.destination(for: file))
    }
    func testPlanDoesNotRecopyExistingAPKAndDetectsTruncatedAPK() throws {
        let file = try XCTUnwrap(frozenRecipe().files.first), source = URL(fileURLWithPath: "/fixture/apk")
        let path = try XCTUnwrap(StagePlan.destination(for: file))
        XCTAssertTrue(StagePlan.plan(local: [(file, source, 83_919_960)], remote: [path: 83_919_960]).isEmpty)
        XCTAssertEqual(StagePlan.plan(local: [(file, source, 83_919_960)], remote: [path: 100]).count, 1)
    }
    func testMissingAPKRepairKeepsSixOBBsAndAllReceiptsThenIsIdempotent() throws {
        let helper = StageResume151Tests(), root = try helper.scratch(), fixture = try helper.fixture(root)
        let file = try XCTUnwrap(frozenRecipe().files.first), source = root.appendingPathComponent("selected.apk")
        try Data("selected variant APK bytes".utf8).write(to: source)
        let apk = try InstallationContent.entry(source: source, destination: XCTUnwrap(StagePlan.destination(for: file)),
            cache: SHA256FileCache(root: root.appendingPathComponent("hash-cache")))
        var current: RemoteFile?, writes: [String] = [], reads: [String] = []
        let container = InstallationContent.Container(stat: { path in
            path == apk.destination ? current : helper.stat(fixture, path)
        }, fetch: { path, destination in
            reads.append(path); XCTAssertEqual(path, apk.destination, "No 20 GB OBB readback")
            try Data(contentsOf: source).write(to: destination)
        }, put: { _, path in
            writes.append(path); XCTAssertEqual(path, apk.destination, "No OBB retransmission")
            current = RemoteFile(relativePath: file.localName!, size: apk.size, isDirectory: false, modified: Date(timeIntervalSince1970: 200))
        })
        try InstallationContent.sync(fixture.entries + [apk], container: container, receipts: fixture.receipt)
        let after = try InstallationContent.loadReceipts(fixture.receipt)
        for (key, value) in fixture.known { XCTAssertEqual(after[key], value) }
        XCTAssertEqual(writes, [apk.destination]); XCTAssertEqual(reads, [apk.destination])
        try InstallationContent.sync(fixture.entries + [apk], container: container, receipts: fixture.receipt)
        XCTAssertEqual(writes, [apk.destination]); XCTAssertEqual(reads, [apk.destination])
    }
    func testMetadataQueryFailureBlocksMissingAPKWithoutTouchingReceipts() throws {
        let helper = StageResume151Tests(), fixture = try helper.fixture(helper.scratch())
        let before = try Data(contentsOf: fixture.receipt)
        let apk = InstallationContent.Entry(source: fixture.receipt, destination: "Documents/x6072194326150034.apk", size: 83_919_960, sha256: String(repeating: "a", count: 64))
        let meta = InstallationContent.Entry(source: fixture.receipt, destination: helper.metadata, size: 8988, sha256: String(repeating: "b", count: 64))
        XCTAssertThrowsError(try InstallationContent.sync(fixture.entries + [apk, meta], container: .init(stat: { path in
            if path == helper.metadata { throw DeviceError.tool("DDI metadata unavailable") }
            return helper.stat(fixture, path)
        }, fetch: { _, _ in XCTFail() }, put: { _, _ in XCTFail("Missing APK is not permission to copy during an inconclusive query") }), receipts: fixture.receipt))
        XCTAssertEqual(try Data(contentsOf: fixture.receipt), before)
    }
    func testJobWithCompletedBuildCanRepairAPKByStageOnly() async throws {
        let helper = StageResume151Tests(), root = try helper.scratch(), store = JobStore(directory: root)
        let runtime = try Verified850Fixture.source()
        var job = Job(recipe: try frozenRecipe(), request: InstallRequest(toolchain: runtime.root.path), steps: [.fetch,.build,.stage], toolchainCommit: runtime.commit())
        job.completed = [.fetch,.build]; job.state = .failed; job.failureKind = .device; job.attempts = 4
        try store.save(job)
        let resumed = try store.prepareResume(job.id)
        XCTAssertEqual(resumed.remaining, [.stage])
        let done = try await JobRunner(store: store).run(resumed, currentToolchain: runtime.commit()) { step, persisted in
            XCTAssertEqual(step, .stage)
            XCTAssertEqual(StagePlan.destination(for: persisted.recipe.files[0]), "Documents/x6072194326150034.apk")
        }
        XCTAssertEqual(done.state, .finished)
    }
}
