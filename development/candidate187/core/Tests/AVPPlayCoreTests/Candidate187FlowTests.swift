import XCTest
@testable import AVPPlayCore

final class Candidate187FlowTests: XCTestCase {
    func testProvisioningCommandOnlyBuildsLocallyForExplicitDevice() {
        let command = ProfileProvisioning.automaticCommand(project: URL(fileURLWithPath: "/tmp/setup/ProfileSetup.xcodeproj"), device: "test-device")
        XCTAssertEqual(command.executable.path, "/usr/bin/xcodebuild")
        XCTAssertTrue(command.arguments.contains("-allowProvisioningUpdates"))
        XCTAssertTrue(command.arguments.contains("id=test-device"))
        XCTAssertEqual(command.arguments.last, "build")
        XCTAssertFalse(command.arguments.contains("install"))
        XCTAssertFalse(command.arguments.contains("run"))
        XCTAssertFalse(command.arguments.contains("clean"))
    }
    func testFreshBuildIntentSurvivesJobPersistenceAndResume() throws {
        let root = DataLocation.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let recipe = try RecipeStore(directory: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("recipes")).load(id: "store-3240283705987790")
        var request = InstallRequest(toolchain: "/test/runtime")
        request.freshLocalBuildID = UUID().uuidString
        request.localAPKVariantID = "fixture"
        var job = Job(recipe: recipe, request: request, steps: InstallStep.localAPKInstall, toolchainCommit: "cc2856c")
        job.state = .failed
        let store = JobStore(directory: root)
        try store.save(job)
        let resumed = try store.prepareResume(job.id)
        XCTAssertEqual(resumed.request.freshLocalBuildID, request.freshLocalBuildID)
        XCTAssertNotEqual(resumed.request.reuseBuildOnly, true)
        XCTAssertEqual(resumed.id, job.id)
    }
    func testParadiseFreshPrepareAndNativeBuildWithoutDevice() throws {
        guard let path = ProcessInfo.processInfo.environment["AVPPLAY187_SOURCE_JOB"] else {
            throw XCTSkip("Explicit real-game Job path required; ordinary tests use synthetic inputs")
        }
        let url = URL(fileURLWithPath: path)
        let before = try Data(contentsOf: url)
        let jobs = JobStore(directory: url.deletingLastPathComponent())
        let job = try jobs.load(url.deletingPathExtension().lastPathComponent)
        XCTAssertEqual(job.recipe.package, "com.wanadev.propagation_ph")
        let registry = LocalAPKVariantStore(root: URL(fileURLWithPath: try XCTUnwrap(job.request.localVariantStorePath)))
        let variantID = try XCTUnwrap(job.request.localAPKVariantID)
        let selected = try registry.validatedForPreparation(id: variantID, for: job.recipe)
        XCTAssertTrue(selected.variant.assets?.contains(where: { ($0.destination?.hasSuffix("/br.png") == true) }) == true)
        let runtime = try Verified850Fixture.source()
        let root = DataLocation.base.appendingPathComponent("paradise-real-validation")
        let store = ContentStore(root: root.appendingPathComponent("store"))
        let prepared = try LocalAPKPreparer().prepareIsolated(recipe: job.recipe, variantID: variantID,
            store: store, toolchain: runtime, localVariants: registry,
            workspaceRoot: root.appendingPathComponent("prepared"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.appendingPathComponent(".qi-prepared").path))
        var environment = try runtime.runtimeEnvironment(recipe: KleptonRecipeCompatibility.resolve(job.recipe), request: job.request)
        environment["KLEPTON_APP_VERSION"] = "1.3.1"
        environment["KLEPTON_APP_BUILD"] = AppStamp.build(versionCode: 47, toolchainVersion: 850, modified: true)
        let result = try runtime.buildOnly(recipe: job.recipe, store: store, localAPKVariantID: variantID,
            localVariants: registry, bundleID: job.request.bundleId ?? Toolchain.defaultBundleId(target: job.recipe.toolchain.target),
            workspaceRoot: root.appendingPathComponent("build"), extraEnvironment: environment)
        let info = try ReusableBuild.infoPlist(result.app.appendingPathComponent("Info.plist"))
        let artifact = ReusableBuild(app: result.app, workspace: result.workspace, sourceJobID: "real-validation187",
            bundleID: try XCTUnwrap(info["CFBundleIdentifier"] as? String), files: try ReusableBuild.inventory(result.app))
        try RuntimePolicy177.requireArtifact(artifact, target: job.recipe.toolchain.target)
        XCTAssertEqual(try Data(contentsOf: url), before)
        print("PARADISE_FRESH_BUILD=\(result.app.path)")
        print("PARADISE_BUILD_LOG=\(result.log.path)")
    }

    func testParadiseLocalSignatureUsesExistingProfileWithoutDeviceAccess() throws {
        guard let appPath = ProcessInfo.processInfo.environment["AVPPLAY187_BUILT_APP"],
              let jobPath = ProcessInfo.processInfo.environment["AVPPLAY187_SOURCE_JOB"] else {
            throw XCTSkip("Explicit locally built app and Job required")
        }
        _ = try Verified850Fixture.source()
        let url = URL(fileURLWithPath: jobPath)
        let job = try JobStore(directory: url.deletingLastPathComponent()).load(url.deletingPathExtension().lastPathComponent)
        let app = URL(fileURLWithPath: appPath)
        let boundary = try XCTUnwrap(appPath.range(of: "/visionos/build/"))
        let workspace = URL(fileURLWithPath: String(appPath[..<boundary.lowerBound]))
        let info = try ReusableBuild.infoPlist(app.appendingPathComponent("Info.plist"))
        let artifact = ReusableBuild(app: app, workspace: workspace, sourceJobID: "validation187",
            bundleID: try XCTUnwrap(info["CFBundleIdentifier"] as? String), files: try ReusableBuild.inventory(app))
        try RuntimePolicy177.requireArtifact(artifact, target: job.recipe.toolchain.target)
        let device = Device(udid: try XCTUnwrap(job.request.device), name: "Stored UDID; no device access", osVersion: "27",
            reachable: false, paired: false, developerMode: false)
        let signed = try ExistingAppSigner.sign(artifact, team: try XCTUnwrap(job.request.team), device: device,
            outputRoot: DataLocation.base.appendingPathComponent("local-sign-validation"), report: { print($0) })
        XCTAssertGreaterThan(signed.expires, Date())
        XCTAssertTrue(FileManager.default.fileExists(atPath: signed.app.appendingPathComponent("embedded.mobileprovision").path))
        XCTAssertEqual(try ReusableBuild.inventory(app), artifact.files)
        print("PARADISE_SIGNED_COPY=\(signed.app.path)")
    }

    func testLaunchRequiresCompletedTransferAndExactVariant() throws {
        let recipe = try RecipeStore(directory: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("recipes")).load(id: "store-3240283705987790")
        var request = InstallRequest(toolchain: "/fixture")
        request.localAPKVariantID = "selected"; request.device = "device"; request.bundleId = "test.fixture.game"
        var job = Job(recipe: recipe, request: request, steps: InstallStep.localAPKInstall, toolchainCommit: "cc2856c")
        job.state = .finished; job.completed = [.fetch, .build]
        XCTAssertThrowsError(try AutomaticLocalInstall.launchIdentity(from: job, variantID: "selected"))
        job.completed.append(.stage)
        XCTAssertEqual(try AutomaticLocalInstall.launchIdentity(from: job, variantID: "selected").bundle, "test.fixture.game")
        XCTAssertThrowsError(try AutomaticLocalInstall.launchIdentity(from: job, variantID: "other"))
        job.state = .failed
        XCTAssertThrowsError(try AutomaticLocalInstall.launchIdentity(from: job, variantID: "selected"))
    }
    func testLaunchCommandAndFailureAreCheckedWithoutTouchingDevice() throws {
        let device = Device(udid: "fixture", name: "fixture", osVersion: "27", reachable: true, paired: true, developerMode: true)
        let success = DeviceControl(query: { args in
            XCTAssertEqual(args, ["device", "process", "launch", "--device", "fixture", "--environment-variables", "{}", "test.fixture.game"])
            return Data("{\"info\":{\"outcome\":\"success\"}}".utf8)
        })
        try success.launch(bundle: "test.fixture.game", device: device)
        let failure = DeviceControl(query: { _ in Data("{\"info\":{\"outcome\":\"failed\"}}".utf8) })
        XCTAssertThrowsError(try failure.launch(bundle: "test.fixture.game", device: device))
        let invalid = DeviceControl(query: { _ in XCTFail("Invalid identity must never reach devicectl"); return Data() })
        XCTAssertThrowsError(try invalid.launch(bundle: "../bad", device: device))
    }

}
