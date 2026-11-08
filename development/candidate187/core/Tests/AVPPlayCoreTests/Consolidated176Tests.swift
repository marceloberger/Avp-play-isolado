import XCTest
@testable import AVPPlayCore

final class Consolidated176Tests: XCTestCase {
    func testBothRuleContractsLoadAndRejectWrongPackagesAndUnsafeDestinations() {
        for override in [Klepton824RecipeRules.obbOverride, Klepton850RecipeRules.obbOverride] {
            XCTAssertEqual(override("x9531494193591052", "com.FireproofStudios.GhostTown"),
                           "android-files/Android/obb/com.FireproofStudios.GhostTown")
            XCTAssertNil(override("x9531494193591052", "com.other.game"))
            XCTAssertNil(override("../target", "../package"))
        }
        XCTAssertNil(Klepton824RecipeRules.obbOverride(target: "x3635172946605196", package: "com.brink.vr.oculus.quest"))
        XCTAssertEqual(Klepton850RecipeRules.obbOverride(target: "x3635172946605196", package: "com.brink.vr.oculus.quest"),
                       "android-files/Android/obb/com.brink.vr.oculus.quest")
        for version in [824, 850] {
            XCTAssertEqual(RecipeValidation176.obbDirectory(target: nil, package: "com.test.game", engine: .nativeActivity, version: version),
                           "android-files/Android/obb/com.test.game")
            XCTAssertNil(RecipeValidation176.obbDirectory(target: nil, package: "../escape", engine: .nativeActivity, version: version))
        }
    }

    func testIdentityTargetEngineFailsClosedIncludingUnknownEngine() {
        let identity = AutomaticAPKIdentity(title: "Fixture", package: "com.test.game", appID: "123456", source: "fixture", targetEngine: "unity")
        let unity = ApkUnpacker.Inspection(package: "com.test.game", versionCode: "1", architectures: ["arm64-v8a"], files: 2,
            nativeLibraries: ["lib/arm64-v8a/libunity.so", "lib/arm64-v8a/libmain.so"])
        XCTAssertTrue(RecipeValidation176.identityBlockers(unity, identity: identity).isEmpty)
        var mismatch = unity
        mismatch.nativeLibraries = ["lib/arm64-v8a/libUE4.so"]
        XCTAssertFalse(RecipeValidation176.identityBlockers(mismatch, identity: identity).isEmpty)
        mismatch.nativeLibraries = []
        XCTAssertFalse(RecipeValidation176.identityBlockers(mismatch, identity: identity).isEmpty)
    }

    func testPrepareAndBuildSharedValidatorRejectsEngineMismatchForBothRuntimes() throws {
        let identity = try XCTUnwrap(AutomaticAPKIdentity.bundled.first { $0.targetEngine == "unity" })
        var recipe = try CommunityAPKStage152Tests().frozenRecipe()
        recipe.package = identity.package
        let apk = ApkUnpacker.Inspection(package: identity.package, versionCode: identity.targetVersionCode ?? "1",
            architectures: ["arm64-v8a"], files: 1, nativeLibraries: ["lib/arm64-v8a/libUE4.so"])
        for version in [824, 850] {
            XCTAssertThrowsError(try RecipeValidation176.validate(apk, recipe: recipe, version: version))
        }
    }
    func testLegacyPinsResolveOnlyTo850WithoutSilentFallbackOrMigration() throws {
        let root = try Verified850Fixture.source().root.deletingLastPathComponent()
        let packager = ToolchainPackager(root: root)
        let recipe = try CommunityAPKStage152Tests().frozenRecipe()
        for (version, commit) in [(824, "a61188d"), (850, "cc2856c")] {
            let choices = ToolchainChoices(games: [recipe.id: .init(version: version, commit: commit)])
            let selected = try XCTUnwrap(packager.selectedToolchain(for: recipe, choices: choices))
            XCTAssertEqual(selected.version(), 850); XCTAssertEqual(selected.commit(), "cc2856c")
            XCTAssertEqual(choices.games[recipe.id]?.version, version)
            XCTAssertEqual(choices.games[recipe.id]?.commit, commit)
        }
        let unavailable = ToolchainPackager(root: FileManager.default.temporaryDirectory.appendingPathComponent("missing-runtime177-\(UUID())"))
        XCTAssertNil(unavailable.selectedToolchain(for: recipe, choices: .init(games: [recipe.id: .init(version: 824, commit: "a61188d")])))
    }

    func testLegacyArtifactRecoveryIsBlockedAndHistoryRemainsUnchanged() throws {
        let helper = ResumeReuseTests()
        let (_, workspace, _, recipe, jobs, original, originalRequest, toolchain, hash, _) = try helper.legacyTimestampFixture()
        let variant = LocalAPKVariant(id: "fixture-local-apk", recipeID: recipe.id, recipeVersionCode: recipe.versionCode,
            relativePath: "fixture.apk", size: 123, sha256: hash, package: recipe.package,
            versionCode: String(recipe.versionCode), architectures: ["arm64-v8a"], source: "local",
            trustStatus: "local-unverified", official: false, recipeValidated: false, registeredAt: Date())
        var request = originalRequest
        request.localAssetsSHA256 = try LocalAPKBuildEvidence.assetsHash(variant)
        var good = original; good.request = request; good.updated = Date().addingTimeInterval(2)
        try jobs.save(good)
        let goodBytes = try Data(contentsOf: jobs.url(good.id))
        var bad = Job(recipe: recipe, request: request, steps: [.buildOnly], toolchainCommit: toolchain.commit(), suffix: "missing-log")
        bad.state = .finished; bad.completed = [.buildOnly]; bad.created = good.created.addingTimeInterval(20)
        try jobs.save(bad)
        let recovery = LocalBuildRecovery(workspaceRoot: workspace)
        try FileManager.default.createDirectory(at: recovery.directory, withIntermediateDirectories: true)
        let malformed = recovery.directory.appendingPathComponent(recipe.id + "-malformed.json")
        let bytes = Data("preserved malformed receipt".utf8); try bytes.write(to: malformed)
        let jobBytes = try Data(contentsOf: jobs.url(bad.id))
        XCTAssertThrowsError(try recovery.artifact(jobs: jobs, recipe: recipe, variant: variant, toolchain: toolchain, requestedRuntime: request))
        XCTAssertEqual(try Data(contentsOf: malformed), bytes)
        XCTAssertEqual(try Data(contentsOf: jobs.url(bad.id)), jobBytes)
        XCTAssertEqual(try Data(contentsOf: jobs.url(good.id)), goodBytes)
        var wrong = request; wrong.frameGeneration = .between
        XCTAssertFalse(LocalBuildRecovery.runtimeCompatible(request, with: wrong))
    }

}
