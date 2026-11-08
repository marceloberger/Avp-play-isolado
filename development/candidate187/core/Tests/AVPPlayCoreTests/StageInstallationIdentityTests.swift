import XCTest
@testable import AVPPlayCore

final class StageInstallationIdentityTests: XCTestCase {
    private func fixture() throws -> (Recipe, LocalAPKVariant, LocalAPKLearningStore, LocalAPKInstallation) {
        let helper = FunctionalityConfirmationTests()
        let (recipe, variant, store) = try helper.fixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: store.root.deletingLastPathComponent()) }
        var original = try helper.receipt(variant, recipe: recipe)
        original.jobID = "native-install-owner"
        try store.recordInstallation(original, variant: variant, recipe: recipe)
        return (recipe, variant, store, original)
    }
    private func bytes(_ store: LocalAPKLearningStore, _ recipe: Recipe) throws -> Data {
        let paths = try FileManager.default.contentsOfDirectory(at: store.root, includingPropertiesForKeys: nil)
        let path = try XCTUnwrap(paths.first { $0.pathExtension == "json" })
        return try Data(contentsOf: path)
    }
    func testStageJobReusesExactInstallationOwnerWithoutRewritingHistory() throws {
        let (recipe, variant, store, original) = try fixture()
        let before = try bytes(store, recipe)
        var stage = original; stage.jobID = "transfer-job"
        let result = try store.recordInstallationAfterStage(stage, variant: variant, recipe: recipe)
        XCTAssertEqual(result, original)
        XCTAssertEqual(try bytes(store, recipe), before)
        XCTAssertEqual(try store.load(recipe).installations.count, 1)
        XCTAssertEqual(try store.recordInstallationAfterStage(stage, variant: variant, recipe: recipe), original)
    }
    func testStageKeepsConfirmationAndRevocationAndNeverLearnsHashes() throws {
        let (recipe, variant, store, original) = try fixture()
        try store.setFunctionality(receiptID: original.id, variant: variant, recipe: recipe, confirmed: true)
        let before = try bytes(store, recipe), saved = try store.load(recipe)
        var stage = original; stage.jobID = "transfer-job"
        XCTAssertEqual(try store.recordInstallationAfterStage(stage, variant: variant, recipe: recipe), saved.installations[0])
        XCTAssertEqual(try bytes(store, recipe), before)
        try store.setFunctionality(receiptID: original.id, variant: variant, recipe: recipe, confirmed: false)
        let revoked = try bytes(store, recipe)
        _ = try store.recordInstallationAfterStage(stage, variant: variant, recipe: recipe)
        XCTAssertEqual(try bytes(store, recipe), revoked)
        XCTAssertNil(try store.load(recipe).current)
    }
    func testSameIDCannotBeClaimedByDifferentDeviceBundleBuildDateOrConfiguration() throws {
        let (recipe, variant, store, original) = try fixture()
        let before = try bytes(store, recipe)
        var changedBuild = original; changedBuild.build?.signedBuildSHA256 = String(repeating: "e", count: 64)
        var changedDate = original; changedDate.date.addTimeInterval(1)
        var changedDevice = original; changedDevice.deviceID = "another-device"; changedDevice.configuration?.device = "another-device"
        var changedBundle = original; changedBundle.bundleID = "other.game"; changedBundle.configuration?.bundleId = "other.game"
        var changedConfiguration = original; changedConfiguration.configuration?.toolchain = "/other/workspace"
        for var conflict in [changedBuild, changedDate, changedDevice, changedBundle, changedConfiguration] {
            conflict.jobID = "transfer-job"
            XCTAssertThrowsError(try store.recordInstallationAfterStage(conflict, variant: variant, recipe: recipe)) { error in
                XCTAssertTrue("\(error)".contains("native-install-owner"))
                XCTAssertTrue("\(error)".contains("campos divergentes="))
            }
            XCTAssertEqual(try bytes(store, recipe), before)
        }
    }
    func testNonStageWriterStillRejectsOwnershipChangeAndReportsOriginalOwner() throws {
        let (recipe, variant, store, original) = try fixture()
        var collision = original; collision.jobID = "different-install-job"
        XCTAssertThrowsError(try store.recordInstallation(collision, variant: variant, recipe: recipe)) { error in
            XCTAssertTrue("\(error)".contains("native-install-owner"))
            XCTAssertTrue("\(error)".contains("different-install-job"))
            XCTAssertTrue("\(error)".contains("jobID"))
        }
        XCTAssertEqual(try store.load(recipe).installations, [original])
    }
    func testDifferentInstallationIDNeverInheritsAnotherOwnersAssociation() throws {
        let (recipe, variant, store, original) = try fixture()
        var next = original; next.id = "distinct-installation"; next.jobID = "another-native-owner"
        next.date.addTimeInterval(60)
        let result = try store.recordInstallationAfterStage(next, variant: variant, recipe: recipe)
        XCTAssertEqual(result.jobID, "another-native-owner")
        XCTAssertEqual(try store.load(recipe).installations, [original, next])
    }
    func testLegacyReceiptWithoutOwnerCannotBeTakenOverByStageJob() throws {
        let (recipe, variant, store, original) = try fixture()
        var legacy = original; legacy.id = "legacy"; legacy.jobID = nil
        try store.recordInstallation(legacy, variant: variant, recipe: recipe)
        let before = try bytes(store, recipe)
        var stage = legacy; stage.jobID = "transfer-job"
        XCTAssertNil(try store.recordInstallationAfterStage(stage, variant: variant, recipe: recipe).jobID)
        XCTAssertEqual(try bytes(store, recipe), before)
    }
}
