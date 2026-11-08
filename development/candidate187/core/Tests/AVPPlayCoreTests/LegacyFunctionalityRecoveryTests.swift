import XCTest
@testable import AVPPlayCore

final class LegacyFunctionalityRecoveryTests: XCTestCase {
    struct Fixture {
        let base: URL
        let recipe: Recipe
        let variant: LocalAPKVariant
        let variants: LocalAPKVariantStore
        let store: ContentStore
        let jobs: JobStore
        let receipt: LocalAPKInstallation
        let unsigned: URL
        let signed: URL
        let install: Job
        let build: Job
        var learning: LocalAPKLearningStore { LocalAPKLearningStore(variants: variants) }
        func prepare(verify: (URL, LocalAPKInstallation) throws -> Void = { _,_ in }) throws -> LocalAPKInstallation {
            try LegacyFunctionalityRecovery.prepare(receipt: receipt, variant: variant, recipe: recipe,
                variants: variants, store: store, jobs: jobs, base: base, verifySignature: verify)
        }
    }
    func write(_ value: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try value.write(to: url, atomically: true, encoding: .utf8)
    }
    func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-functionality-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let recipes = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("recipes")
        let recipe = try RecipeStore(directory: recipes).load(id: "batman")
        let variants = LocalAPKVariantStore(root: root.appendingPathComponent("variants"))
        let variant = try variants.register(from: LocalAPKVariantTests().makeAPK(in: root), recipe: recipe)
        let learning = LocalAPKLearningStore(variants: variants)
        try learning.authorize(variant, recipe: recipe, allowed: true)
        let jobs = JobStore(directory: root.appendingPathComponent("jobs"))
        let store = ContentStore(root: root.appendingPathComponent("store"))
        var request = InstallRequest(toolchain: root.appendingPathComponent("toolchain").path)
        request.team = "TESTTEAM01"; request.device = "vision-pro"; request.bundleId = "test.legacy.game"
        request.localAPKVariantID = variant.id; request.localVariantStorePath = variants.root.path
        request.localWorkspaceRoot = root.appendingPathComponent("build-only").path
        let time = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down) + 100)
        var build = Job(recipe: recipe, request: request, steps: [.buildOnly], toolchainCommit: "fixture")
        build.state = .finished; build.completed = [.buildOnly]; build.created = time.addingTimeInterval(-60); build.updated = time.addingTimeInterval(-50)
        try jobs.save(build)
        var install = Job(recipe: recipe, request: request, steps: InstallStep.localAPKInstall, toolchainCommit: "fixture")
        install.state = .finished; install.completed = InstallStep.localAPKInstall
        install.created = time.addingTimeInterval(-40); install.updated = time.addingTimeInterval(-10)
        try jobs.save(install)
        let receipt = LocalAPKInstallation(id: "legacy-receipt", variantID: variant.id, sha256: variant.sha256,
            size: variant.size, package: variant.package, versionCode: variant.versionCode, bundleID: "test.legacy.game",
            deviceID: "vision-pro", team: "TESTTEAM01", toolchain: "750-fixture", date: time.addingTimeInterval(-20))
        try learning.recordInstallation(receipt, variant: variant, recipe: recipe)
        let id = UUID().uuidString.lowercased(), workspace = root.appendingPathComponent("build-only/game-\(id)")
        let unsigned = workspace.appendingPathComponent("visionos/build/avpplay-build-only/\(id)/DerivedData/Build/Products/Debug-xros/Game.app")
        let target = KleptonRecipeCompatibility.resolve(recipe).toolchain.target
        let info: [String: Any] = ["CFBundleIdentifier": receipt.bundleID, "CFBundleExecutable": "Game", "CFBundleVersion": "\(recipe.versionCode).750",
            "CFBundleSupportedPlatforms": ["XROS"], "KLTree": target, "KLControllerModeDefault": "standard",
            "KLRoomGuardDefault": "1", "KLGameLanguageDefault": "", "KLTestOn": "", "KLRenderScaleDefault": "1.00"]
        try FileManager.default.createDirectory(at: unsigned, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: unsigned.appendingPathComponent("Info.plist"))
        try write("unchanged code fixture", unsigned.appendingPathComponent("Game"))
        try write("local:\(variant.id):\(variant.sha256) \(variant.versionCode) icon4 - -", workspace.appendingPathComponent(target + "/.qi-prepared"))
        try write("** BUILD SUCCEEDED **\n[exit 0]", workspace.appendingPathComponent("build-only.log"))
        try write("{\"version\":750,\"commit\":\"fixture\"}", workspace.appendingPathComponent("toolchain.json"))
        try write("Generic visionOS app built at \(unsigned.path)", jobs.directory.appendingPathComponent(build.id + ".log"))
        try write("Reutilizando app do Job \(build.id). Nenhuma compilação será executada.\nApp existente assinado e instalação confirmada.\nDone", jobs.directory.appendingPathComponent(install.id + ".log"))
        let signed = root.appendingPathComponent("signed-existing/fixture/Game.app")
        try FileManager.default.createDirectory(at: signed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: unsigned, to: signed)
        try write("fixture public profile", signed.appendingPathComponent("embedded.mobileprovision"))
        try write("/usr/bin/codesign --verify --deep --strict \(signed.path)\n\n[exit 0]", signed.deletingLastPathComponent().appendingPathComponent("sign-existing.log"))
        let record = SigningRecord(team: receipt.team, free: true, installed: receipt.date, expires: time.addingTimeInterval(86400),
            bundleId: receipt.bundleID, localAPKVariantID: variant.id, localVariantStorePath: variants.root.path, toolchainPath: request.toolchain)
        try record.write(to: SigningRecord.url(store: store, recipe: recipe))
        return Fixture(base: root, recipe: recipe, variant: variant, variants: variants, store: store, jobs: jobs,
                       receipt: receipt, unsigned: unsigned, signed: signed, install: install, build: build)
    }
    func testLegacyRecoveryIsReadOnlyAndOnlyExplicitConfirmationUpgradesSameReceipt() throws {
        let f = try fixture()
        let before = try f.learning.load(f.recipe)
        let jobBefore = try Data(contentsOf: f.jobs.url(f.install.id))
        let unsignedBefore = try ReusableBuild.inventory(f.unsigned), signedBefore = try ReusableBuild.inventory(f.signed)
        var verifications = 0
        let proposal = try f.prepare { app, receipt in
            verifications += 1; XCTAssertEqual(app.resolvingSymlinksInPath(), f.signed.resolvingSymlinksInPath()); XCTAssertEqual(receipt, f.receipt)
        }
        XCTAssertEqual(verifications, 1)
        XCTAssertEqual(try f.learning.load(f.recipe), before)
        XCTAssertNil(proposal.confirmedAt); XCTAssertNil(proposal.functionalityStatus)
        XCTAssertEqual(proposal.configuration?.roomMeasuring, true)
        XCTAssertEqual(proposal.configuration?.gameLanguage, "")
        XCTAssertEqual(proposal.configuration?.experimental, false)
        XCTAssertEqual(proposal.configuration?.metalFX, false)
        XCTAssertEqual(proposal.legacyRecovery?.installationJobID, f.install.id)
        let now = Date()
        try f.learning.confirmRecoveredInstallation(proposal, variant: f.variant, recipe: f.recipe, now: now)
        let reopened = LocalAPKLearningStore(variants: f.variants)
        let saved = try XCTUnwrap(reopened.latestInstallations(variant: f.variant, recipe: f.recipe).first)
        XCTAssertEqual(saved.confirmedAt, now); XCTAssertEqual(saved.id, f.receipt.id)
        XCTAssertEqual(try reopened.load(f.recipe).installations.count, 1)
        XCTAssertEqual(try Data(contentsOf: f.jobs.url(f.install.id)), jobBefore)
        XCTAssertEqual(try ReusableBuild.inventory(f.unsigned), unsignedBefore)
        XCTAssertEqual(try ReusableBuild.inventory(f.signed), signedBefore)
        try reopened.setFunctionality(receiptID: saved.id, variant: f.variant, recipe: f.recipe, confirmed: false)
        XCTAssertNil(try reopened.load(f.recipe).installations[0].functionalityStatus)
    }
    func testRecoveredConfirmationCanDeclineHashAndRestoreDoesNotLearnIt() throws {
        let f = try fixture(), proposal = try f.prepare()
        try f.learning.confirmRecoveredInstallation(proposal, variant: f.variant, recipe: f.recipe, saveConfirmedHash: false)
        XCTAssertNotNil(try f.learning.load(f.recipe).installations[0].functionalityStatus)
        XCTAssertNil(try f.learning.load(f.recipe).current)
        try f.learning.restore(nil, recipe: f.recipe)
        XCTAssertNil(try f.learning.load(f.recipe).current?.hashes[f.variant.sha256])
    }

    func testMissingArtifactsFailedJobAndUnverifiedSignatureNeverProduceProposal() throws {
        let f = try fixture()
        XCTAssertThrowsError(try f.prepare { _,_ in throw LocalAPKVariantError.invalidRecord("Signature invalid") })
        var failed = f.install; failed.state = .failed; try f.jobs.save(failed)
        XCTAssertThrowsError(try f.prepare())
        try f.jobs.save(f.install)
        try FileManager.default.removeItem(at: f.signed)
        XCTAssertThrowsError(try f.prepare())
        XCTAssertNil(try f.learning.load(f.recipe).installations[0].confirmedAt)
    }
    func testChangedAPKOrProductAndUnknownEssentialSettingsAreRejected() throws {
        let f = try fixture()
        let apk = f.variants.root.appendingPathComponent(f.variant.relativePath)
        let original = try Data(contentsOf: apk)
        try Data(repeating: 0, count: original.count).write(to: apk)
        XCTAssertThrowsError(try f.prepare())
        try original.write(to: apk)
        try write("changed code fixture", f.signed.appendingPathComponent("Game"))
        XCTAssertThrowsError(try f.prepare())
        var info = try ReusableBuild.infoPlist(f.unsigned.appendingPathComponent("Info.plist"))
        info.removeValue(forKey: "KLGameLanguageDefault")
        XCTAssertThrowsError(try LegacyFunctionalityRecovery.configuration(request: f.install.request, info: info))
        info["KLGameLanguageDefault"] = ""; info["KLTestOn"] = "UNKNOWN_FLAG"
        XCTAssertThrowsError(try LegacyFunctionalityRecovery.configuration(request: f.install.request, info: info))
    }
    func testAmbiguousSignedCopyAndMissingSigningReceiptAreRejected() throws {
        let f = try fixture()
        let duplicate = f.base.appendingPathComponent("signed-existing/duplicate/Game.app")
        try FileManager.default.createDirectory(at: duplicate.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: f.signed, to: duplicate)
        try write("/usr/bin/codesign --verify --deep --strict \(duplicate.path)\n\n[exit 0]", duplicate.deletingLastPathComponent().appendingPathComponent("sign-existing.log"))
        XCTAssertThrowsError(try f.prepare())
        try FileManager.default.removeItem(at: duplicate)
        try FileManager.default.removeItem(at: SigningRecord.url(store: f.store, recipe: f.recipe))
        XCTAssertThrowsError(try f.prepare())
    }
    func testStaleProposalCannotChangeOrDuplicateLegacyInstallation() throws {
        let f = try fixture(), proposal = try f.prepare()
        var changed = proposal; changed.bundleID = "test.other"
        XCTAssertThrowsError(try f.learning.confirmRecoveredInstallation(changed, variant: f.variant, recipe: f.recipe))
        try f.learning.confirmRecoveredInstallation(proposal, variant: f.variant, recipe: f.recipe)
        XCTAssertThrowsError(try f.learning.confirmRecoveredInstallation(proposal, variant: f.variant, recipe: f.recipe))
        XCTAssertEqual(try f.learning.load(f.recipe).installations.count, 1)
    }
    func testConfigurationUsesProductEvenWhenJobOptionsWereAbsent() throws {
        let f = try fixture()
        XCTAssertNil(f.install.request.roomMeasuring); XCTAssertNil(f.install.request.gameLanguage)
        var info = try ReusableBuild.infoPlist(f.unsigned.appendingPathComponent("Info.plist"))
        info["KLRoomGuardDefault"] = "0"; info["KLGameLanguageDefault"] = "de"
        let config = try LegacyFunctionalityRecovery.configuration(request: f.install.request, info: info)
        XCTAssertEqual(config.roomMeasuring, false); XCTAssertEqual(config.gameLanguage, "de")
    }

    func testMachOComparisonAllowsOnlySigningChangesAndRejectsCodeChanges() throws {
        // Thin ARM64 header, a __LINKEDIT command and reserved load-command padding; no executable runs.
        var unsigned = Data(repeating: 0, count: 256)
        func put(_ value: UInt32, at offset: Int, in data: inout Data) {
            for i in 0..<4 { data[offset + i] = UInt8((value >> (i * 8)) & 255) }
        }
        put(0xfeedfacf, at: 0, in: &unsigned); put(0x0100000c, at: 4, in: &unsigned)
        put(1, at: 16, in: &unsigned); put(72, at: 20, in: &unsigned)
        put(0x19, at: 32, in: &unsigned); put(72, at: 36, in: &unsigned)
        unsigned.replaceSubrange(40..<50, with: Data("__LINKEDIT".utf8))
        unsigned[200] = 42
        var signed = unsigned; signed.append(Data(repeating: 9, count: 32))
        put(2, at: 16, in: &signed); put(88, at: 20, in: &signed)
        put(0x1d, at: 104, in: &signed); put(16, at: 108, in: &signed)
        put(256, at: 112, in: &signed); put(32, at: 116, in: &signed)
        put(123, at: 64, in: &signed); put(456, at: 80, in: &signed)
        XCTAssertTrue(try LegacySignedBuild.sameCode(unsigned, signed))
        signed[200] = 43
        XCTAssertFalse(try LegacySignedBuild.sameCode(unsigned, signed))
        put(1024, at: 112, in: &signed)
        XCTAssertThrowsError(try LegacySignedBuild.sameCode(unsigned, signed))
    }
}
