import XCTest
@testable import AVPPlayCore
@testable import AVPPlayApp

final class LocalInstallReadinessTests: XCTestCase {
    private func fixture() throws -> (Recipe, LocalAPKVariant) {
        var record = LocalProvisionalRecipe(apkSHA256: String(repeating: "a", count: 64), apkSize: 123,
            apkPath: "/tmp/synthetic.apk", title: "Local synthetic", package: "com.example.readiness",
            versionName: "1.0", versionCode: "47", architectures: ["arm64-v8a"],
            nativeLibraries: ["lib/arm64-v8a/libUE4.so"], assets: [], externalFileReferences: [],
            externalFiles: [], createdAt: Date())
        record.experimentalTarget = try LocalExperimentalTarget(appID: "123456789",
            provenance: "Synthetic offline test", analysis: record.genericAnalysis)
        let recipe = try XCTUnwrap(record.experimentalRecipe)
        let variant = LocalAPKVariant(id: "synthetic", recipeID: recipe.id, recipeVersionCode: 47,
            relativePath: "synthetic.apk", size: 123, sha256: record.apkSHA256,
            package: record.package, versionCode: "47", versionName: "1.0", architectures: ["arm64-v8a"],
            androidSignature: .init(state: "verified", detail: "Synthetic metadata for UI eligibility only"),
            source: "local", trustStatus: "local-unverified", official: false, recipeValidated: false,
            versionMatchesRecipe: true, registeredAt: Date())
        return (recipe, variant)
    }

    func testEligibleRecipeRequiresAllLocalSetupBeforeInstallButtonCanBeEnabled() throws {
        let (recipe, variant) = try fixture()
        XCTAssertTrue(LocalInstallReadiness.canStart(recipe: recipe, variant: variant,
            runtimeAvailable: true, xcodeAvailable: true, teamValid: true, deviceAvailable: true))
        for missing in 0..<4 {
            XCTAssertFalse(LocalInstallReadiness.canStart(recipe: recipe, variant: variant,
                runtimeAvailable: missing != 0, xcodeAvailable: missing != 1,
                teamValid: missing != 2, deviceAvailable: missing != 3))
        }
    }

    func testSetupCannotEnableUnsignedMismatchedOrPromotedLocalRecipes() throws {
        let (recipe, variant) = try fixture()
        var cases: [LocalAPKVariant] = []
        var invalid = variant; invalid.androidSignature = nil; cases.append(invalid)
        invalid = variant; invalid.versionCode = "48"; cases.append(invalid)
        invalid = variant; invalid.package = "com.other.game"; cases.append(invalid)
        invalid = variant; invalid.trustStatus = "verified"; cases.append(invalid)
        invalid = variant; invalid.missingRequiredFiles = ["required.obb"]; cases.append(invalid)
        for value in cases {
            XCTAssertFalse(LocalInstallReadiness.canStart(recipe: recipe, variant: value,
                runtimeAvailable: true, xcodeAvailable: true, teamValid: true, deviceAvailable: true))
        }
        var promoted = recipe; promoted.status.playability = "verified"
        XCTAssertFalse(LocalInstallReadiness.canStart(recipe: promoted, variant: variant,
            runtimeAvailable: true, xcodeAvailable: true, teamValid: true, deviceAvailable: true))
    }
}
