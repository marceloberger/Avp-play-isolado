import XCTest
import CryptoKit
@testable import AVPPlayCore

final class ResumeReuseTests: XCTestCase {
    func recipe() throws -> Recipe {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("recipes")
        return try RecipeStore(directory: root).load(id: "store-2637179839719680")
    }
    func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("resume-reuse-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func plist(_ value: [String: Any], _ file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0).write(to: file)
    }

    func testDeviceFailureResumesAtPendingStepWithoutRepeatingFetchOrChangingOtherJobs() async throws {
        let root = try scratch(), store = JobStore(directory: root)
        var request = InstallRequest(toolchain: try Verified850Fixture.source().root.path); request.localAPKVariantID = "fixture-apk"
        var job = Job(recipe: try recipe(), request: request, steps: [.fetch, .build, .stage], toolchainCommit: "cc2856c", suffix: "one")
        job.completed = [.fetch]; job.state = .failed; job.current = .build; job.failureKind = .device; job.failure = "No paired, reachable Vision Pro found."
        let other = Job(recipe: try recipe(), request: request, steps: [.buildOnly], toolchainCommit: "cc2856c", suffix: "two")
        try store.save(job); try store.save(other)
        let otherBefore = try Data(contentsOf: store.url(other.id))
        let resumed = try store.prepareResume(job.id)
        XCTAssertEqual(resumed.state, .waiting); XCTAssertNil(resumed.failure); XCTAssertEqual(resumed.completed, [.fetch])
        XCTAssertEqual(resumed.request.requireExistingBuildOnResume, true)
        let called = LockedBox<[InstallStep]>([])
        let finished = try await JobRunner(store: store).run(resumed, currentToolchain: "cc2856c") { step, _ in called.update { $0.append(step) } }
        XCTAssertEqual(called.get(), [.build, .stage]); XCTAssertEqual(finished.state, .finished)
        XCTAssertEqual(try Data(contentsOf: store.url(other.id)), otherBefore)
    }

    func testCannotResumeCancelledFinishedOrPermanentlyUnsupportedJobs() throws {
        let store = JobStore(directory: try scratch())
        for state in [Job.State.cancelled, .finished, .failed] {
            var job = Job(recipe: try recipe(), request: InstallRequest(toolchain: "/fixture"), toolchainCommit: "fixture")
            job.state = state; if state == .failed { job.failureKind = .unsupported }
            try store.save(job); XCTAssertThrowsError(try store.prepareResume(job.id))
        }
    }

    func testDeviceSelectionRequiresFreshPairingReachabilityAndSameUDID() throws {
        let connected = Device(udid: "same", name: "Fixture", osVersion: "27", reachable: true, paired: true, developerMode: true)
        let offline = Device(udid: "same", name: "Fixture", osVersion: "27", reachable: false, paired: true, developerMode: true)
        XCTAssertThrowsError(try DeviceControl.select(devices: [offline], udid: "same"))
        XCTAssertEqual(try DeviceControl.select(devices: [connected], udid: "same").udid, "same")
        XCTAssertThrowsError(try DeviceControl.select(devices: [connected], udid: "another"))
    }

    func testBuildOnlyIsNotDownloadOnlyAndStillChecksFrozenToolchain() async throws {
        let store = JobStore(directory: try scratch())
        let job = Job(recipe: try recipe(), request: InstallRequest(toolchain: try Verified850Fixture.source().root.path), steps: [.buildOnly], toolchainCommit: "cc2856c")
        XCTAssertFalse(job.isDownloadOnly); try store.save(job)
        do {
            _ = try await JobRunner(store: store).run(job, currentToolchain: "changed") { _, _ in XCTFail("No build permitted") }
            XCTFail("Expected toolchain mismatch")
        } catch { XCTAssertEqual(try store.load(job.id).failureKind, .setup) }
    }

    func testModernDevicePropertiesWithoutDeprecatedFieldsAreRecognized() throws {
        let json: [String: Any] = ["result": ["devices": [["properties": [
            "hardware": ["platform": "visionOS", "reality": "physical", "udid": "reconnected"],
            "connection": ["state": "connected", "pairingState": "paired", "transportType": "localNetwork"],
            "software": ["osVersionNumber": ["stringValue": "27.0.1"]],
            "state": ["name": "Vision Pro", "developerModeStatus": ["enabled": ["mode": 1]]]
        ]]]]]
        let devices = try DeviceControl.parseDevices(JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(try DeviceControl.select(devices: devices, udid: "reconnected").osVersion, "27.0.1")
        XCTAssertTrue(devices[0].connected)
    }

    func testEmptyKLTreeRequiresAPKAndFrozenGeneratorEvidence137() throws {
        let recipe = try recipe(), resolved = KleptonRecipeCompatibility.resolve(recipe)
        let apk = try XCTUnwrap(resolved.files.first(where: { $0.role == "apk" })?.localName)
        let info: [String: Any] = ["KLTree": "", "KLApkName": apk]
        XCTAssertTrue(ReusableBuild.matchesTarget(info: info, recipe: recipe, buildLog: "  KLEPTON_TARGET = re4\n"))
        XCTAssertFalse(ReusableBuild.matchesTarget(info: info, recipe: recipe, buildLog: "KLEPTON_TARGET = batman"))
        XCTAssertFalse(ReusableBuild.matchesTarget(info: info, recipe: recipe, buildLog: ""))
        XCTAssertFalse(ReusableBuild.matchesTarget(info: ["KLTree": "", "KLApkName": "other.apk"], recipe: recipe, buildLog: "KLEPTON_TARGET = re4"))
    }

    func testExistingBuildIsVerifiedAndCopyTamperingIsRejectedWithoutAnyCompiler() throws {
        let root = try scratch(), recipe = try recipe()
        let f = try Verified850Fixture.build(root: root, recipe: recipe)
        XCTAssertEqual(f.jobs.all().count, 1)
        XCTAssertEqual(f.workspace.commit(), "cc2856c")
        XCTAssertEqual(f.workspace.version(), 850)
        XCTAssertTrue(ReusableBuild.sameOptions(try f.jobs.load(f.job.id).request, f.request))
        let found = try XCTUnwrap(ReusableBuild.find(jobs: f.jobs, workspaceRoot: f.workspaceRoot,
            recipe: recipe, request: f.request, bundleID: f.artifact.bundleID,
            apkHash: f.variant.sha256, toolchain: f.runtime))
        XCTAssertEqual(found.sourceJobID, f.job.id)
        let copy = root.appendingPathComponent("Copy.app"); try FileManager.default.copyItem(at: f.app, to: copy)
        try found.verifyCopy(copy)
        try Data("modified".utf8).write(to: copy.appendingPathComponent("Fixture"))
        XCTAssertThrowsError(try found.verifyCopy(copy))
        var changed = recipe; changed.title += " changed"
        XCTAssertNil(try ReusableBuild.find(jobs: f.jobs, workspaceRoot: f.workspaceRoot, recipe: changed,
            request: f.request, bundleID: f.artifact.bundleID, apkHash: f.variant.sha256, toolchain: f.runtime))
        var changedOptions = f.request; changedOptions.controllerMode = .surreal
        XCTAssertNil(try ReusableBuild.find(jobs: f.jobs, workspaceRoot: f.workspaceRoot, recipe: recipe,
            request: changedOptions, bundleID: f.artifact.bundleID, apkHash: f.variant.sha256, toolchain: f.runtime))
        XCTAssertNil(try ReusableBuild.find(jobs: f.jobs, workspaceRoot: f.workspaceRoot, recipe: recipe,
            request: f.request, bundleID: "wrong.bundle", apkHash: f.variant.sha256, toolchain: f.runtime))
    }

    func legacyTimestampFixture() throws -> (URL, URL, URL, Recipe, JobStore, Job, InstallRequest, Toolchain, String, [String: String]) {
        let root = try scratch(), recipe = try recipe()
        let f = try Verified850Fixture.build(root: root, recipe: recipe)
        var job = f.job; job.updated = .distantPast; try f.jobs.save(job)
        return (root, f.workspaceRoot, f.app, recipe, f.jobs, job, f.request, f.runtime, f.variant.sha256, f.artifact.files)
    }

    func testLaterCtimeNeedsExactHistoricalManifestAndMatchingJobAndPath() throws {
        let (_, workspaceRoot, app, recipe, jobs, job, request, toolchain, hash, files) = try legacyTimestampFixture()
        let manifest = try LocalAPKBuildEvidence.digest(files)
        XCTAssertThrowsError(try ReusableBuild.find(jobs: jobs, workspaceRoot: workspaceRoot, recipe: recipe,
            request: request, bundleID: "test.fixture.game", apkHash: hash, toolchain: toolchain,
            snapshots: [job], snapshotLogs: [job.id: "AVPPLAY_BUILD_ONLY_APP_PATH=\(app.path)\n"]))

        let verified = VerifiedLegacyBuildManifest(buildJobID: job.id,
            appPath: app.resolvingSymlinksInPath().standardizedFileURL.path, manifestSHA256: manifest)
        let found = try XCTUnwrap(ReusableBuild.find(jobs: jobs, workspaceRoot: workspaceRoot, recipe: recipe,
            request: request, bundleID: "test.fixture.game", apkHash: hash, toolchain: toolchain,
            snapshots: [job], snapshotLogs: [job.id: "AVPPLAY_BUILD_ONLY_APP_PATH=\(app.path)\n"], verifiedLegacyManifest: verified))
        XCTAssertEqual(found.files, files)

        let wrongManifest = VerifiedLegacyBuildManifest(buildJobID: job.id,
            appPath: app.resolvingSymlinksInPath().standardizedFileURL.path, manifestSHA256: String(repeating: "f", count: 64))
        XCTAssertThrowsError(try ReusableBuild.find(jobs: jobs, workspaceRoot: workspaceRoot, recipe: recipe,
            request: request, bundleID: "test.fixture.game", apkHash: hash, toolchain: toolchain,
            snapshots: [job], snapshotLogs: [job.id: "AVPPLAY_BUILD_ONLY_APP_PATH=\(app.path)\n"], verifiedLegacyManifest: wrongManifest))
        let wrongPath = VerifiedLegacyBuildManifest(buildJobID: job.id, appPath: "/other/Fixture.app",
            manifestSHA256: manifest)
        XCTAssertThrowsError(try ReusableBuild.find(jobs: jobs, workspaceRoot: workspaceRoot, recipe: recipe,
            request: request, bundleID: "test.fixture.game", apkHash: hash, toolchain: toolchain,
            snapshots: [job], snapshotLogs: [job.id: "AVPPLAY_BUILD_ONLY_APP_PATH=\(app.path)\n"], verifiedLegacyManifest: wrongPath))
    }

    func testLaterCtimeRejectsTamperedOrMissingNativeFiles() throws {
        let (_, workspaceRoot, app, recipe, jobs, job, request, toolchain, hash, files) = try legacyTimestampFixture()
        let manifest = try LocalAPKBuildEvidence.digest(files)
        let evidence = VerifiedLegacyBuildManifest(buildJobID: job.id,
            appPath: app.resolvingSymlinksInPath().standardizedFileURL.path, manifestSHA256: manifest)
        try Data("tampered".utf8).write(to: app.appendingPathComponent("Fixture"))
        XCTAssertThrowsError(try ReusableBuild.find(jobs: jobs, workspaceRoot: workspaceRoot, recipe: recipe,
            request: request, bundleID: "test.fixture.game", apkHash: hash, toolchain: toolchain,
            snapshots: [job], snapshotLogs: [job.id: "AVPPLAY_BUILD_ONLY_APP_PATH=\(app.path)"], verifiedLegacyManifest: evidence))

        let (_, missingRoot, missingApp, missingRecipe, missingJobs, missingJob, missingRequest, missingToolchain, missingHash, missingFiles) = try legacyTimestampFixture()
        let missingManifest = try LocalAPKBuildEvidence.digest(missingFiles)
        let missingEvidence = VerifiedLegacyBuildManifest(buildJobID: missingJob.id,
            appPath: missingApp.resolvingSymlinksInPath().standardizedFileURL.path, manifestSHA256: missingManifest)
        try FileManager.default.removeItem(at: missingApp.appendingPathComponent("Fixture"))
        XCTAssertThrowsError(try ReusableBuild.find(jobs: missingJobs, workspaceRoot: missingRoot, recipe: missingRecipe,
            request: missingRequest, bundleID: "test.fixture.game", apkHash: missingHash, toolchain: missingToolchain,
            snapshots: [missingJob], snapshotLogs: [missingJob.id: "AVPPLAY_BUILD_ONLY_APP_PATH=\(missingApp.path)"], verifiedLegacyManifest: missingEvidence))
    }

    func profile(team: String = "TEAM000001", device: String = "device", expires: Date = Date().addingTimeInterval(3600)) -> (ExistingAppSigner.Profile, String) {
        let cert = Data("public certificate fixture only".utf8)
        let sha = Insecure.SHA1.hash(data: cert).map { String(format: "%02X", $0) }.joined()
        let values: [String: Any] = ["Platform": ["xrOS"], "TeamIdentifier": [team], "ExpirationDate": expires, "ProvisionedDevices": [device],
            "DeveloperCertificates": [cert], "Entitlements": ["application-identifier": team + ".*", "get-task-allow": true,
                "keychain-access-groups": [team + ".*"], "com.apple.developer.kernel.increased-memory-limit": true]]
        return (ExistingAppSigner.Profile(path: URL(fileURLWithPath: "/fixture/profile"), data: Data(), values: values), sha)
    }

    func testExistingProfileMustMatchTeamDeviceCertificateExpiryAndCapabilities() throws {
        let (profile, identity) = profile()
        let wanted: [String: Any] = ["com.apple.developer.kernel.increased-memory-limit": true,
            "keychain-access-groups": ["$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)"]]
        let valid = try ExistingAppSigner.plan(profiles: [profile], team: "TEAM000001", bundle: "test.game", device: "device", identity: identity, requested: wanted, free: true)
        let entitlements = try XCTUnwrap(PropertyListSerialization.propertyList(from: valid.entitlements, format: nil) as? [String: Any])
        XCTAssertEqual(entitlements["application-identifier"] as? String, "TEAM000001.test.game")
        for (team, device, cert) in [("WRONG00001", "device", identity), ("TEAM000001", "wrong", identity), ("TEAM000001", "device", "wrong")] {
            XCTAssertThrowsError(try ExistingAppSigner.plan(profiles: [profile], team: team, bundle: "test.game", device: device, identity: cert, requested: wanted, free: true))
        }
        XCTAssertThrowsError(try ExistingAppSigner.plan(profiles: [], team: "TEAM000001", bundle: "test.game", device: "device", identity: identity, requested: wanted, free: true))
        let (expired, _) = self.profile(expires: .distantPast)
        XCTAssertThrowsError(try ExistingAppSigner.plan(profiles: [expired], team: "TEAM000001", bundle: "test.game", device: "device", identity: identity, requested: wanted, free: true))
        XCTAssertThrowsError(try ExistingAppSigner.plan(profiles: [profile], team: "TEAM000001", bundle: "test.game", device: "device", identity: identity, requested: ["unapproved-capability": true], free: false))
    }

    func testPersonalTeamUsesExistingOptionalCapabilityPolicyOnly() throws {
        let (profile, identity) = profile()
        let wanted = ["com.apple.developer.kernel.extended-virtual-addressing": true, "com.apple.developer.low-latency-streaming": true]
        XCTAssertNoThrow(try ExistingAppSigner.plan(profiles: [profile], team: "TEAM000001", bundle: "test.game", device: "device", identity: identity, requested: wanted, free: true))
        XCTAssertThrowsError(try ExistingAppSigner.plan(profiles: [profile], team: "TEAM000001", bundle: "test.game", device: "device", identity: identity, requested: wanted, free: false))
    }
}
