import XCTest
@testable import AVPPlayCore

final class LegacySigningEvidenceTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AVPPLAY_VALIDATE_PERSONAL_STATE"] == "1",
            "Personal Batman evidence may update persistent validation caches; explicit opt-in required")
    }
    private var recipe: Recipe {
        get throws {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("recipes")
            return try RecipeStore(directory: root).load(id: "batman")
        }
    }

    private func realBatman() throws -> (Recipe, LocalAPKVariant, SigningRecord, LocalAPKVariantStore, JobStore, ContentStore) {
        let recipe = try recipe
        let base = DataLocation.defaultBase(bundleIdentifier: DataLocation.modifiedBundleIdentifier,
                                            support: DataLocation.applicationSupport)
        let variants = LocalAPKVariantStore(root: base.appendingPathComponent("local-variants"))
        let variant = try XCTUnwrap(variants.variants(for: recipe).first { $0.id == "batman-350961-ed8d7ab7b95a" })
        let store = ContentStore(root: base.appendingPathComponent("store"))
        let signingURL = try XCTUnwrap(SigningRecord.url(store: store, recipe: recipe, bundleId: "marceloberger.dev.klepton.target.batman"))
        let signing = try XCTUnwrap(SigningRecord.read(signingURL))
        return (recipe, variant, signing, variants, JobStore(directory: base.appendingPathComponent("jobs")), store)
    }

    func testRealLegacyBatmanEvidenceRevalidatesPreservedBuildWithoutReadingExternalAssets() throws {
        let (recipe, variant, signing, variants, jobs, store) = try realBatman()
        XCTAssertNil(signing.buildEvidence?.assetsSHA256)
        XCTAssertEqual(variant.sha256, "ed8d7ab7b95a40075d6b1315e2ccb785055c0baed8362bffe549d77b9f664cd7")
        XCTAssertFalse(try LegacySigningEvidence.verify(signing: signing, variant: variant, recipe: recipe,
            variants: variants, jobs: jobs, store: store, verifyNativeFiles: true).isEmpty)
    }

    func testLegacyBatmanEvidenceRejectsWrongAPKRecipeAndNonLegacyRecords() throws {
        let (recipe, variant, signing, variants, jobs, store) = try realBatman()
        var wrongAPK = variant; wrongAPK.sha256 = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try LegacySigningEvidence.verify(signing: signing, variant: wrongAPK, recipe: recipe,
            variants: variants, jobs: jobs, store: store, verifyNativeFiles: false))
        var wrongRecipe = recipe; wrongRecipe.title += " changed"
        XCTAssertThrowsError(try LegacySigningEvidence.verify(signing: signing, variant: variant, recipe: wrongRecipe,
            variants: variants, jobs: jobs, store: store, verifyNativeFiles: false))
        var nonLegacy = signing
        nonLegacy.buildEvidence?.assetsSHA256 = String(repeating: "a", count: 64)
        XCTAssertThrowsError(try LegacySigningEvidence.verify(signing: nonLegacy, variant: variant, recipe: recipe,
            variants: variants, jobs: jobs, store: store, verifyNativeFiles: false))
        let emptyJobs = JobStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        XCTAssertThrowsError(try LegacySigningEvidence.verify(signing: signing, variant: variant, recipe: recipe,
            variants: variants, jobs: emptyJobs, store: store, verifyNativeFiles: false))
    }
}
