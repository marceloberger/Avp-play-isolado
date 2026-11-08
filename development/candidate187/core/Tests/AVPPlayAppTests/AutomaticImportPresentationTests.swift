import XCTest
@testable import AVPPlayApp
@testable import AVPPlayCore

final class AutomaticImportPresentationTests: XCTestCase {
    @MainActor
    func testPrepareRecipeErrorDisplaysItsActualReason() async {
        let error = RecipeError.invalid("Klepton 824: arquivo obrigatório ausente")
        XCTAssertTrue(AppModel.shortLocalError(error).contains("arquivo obrigatório ausente"))
        XCTAssertFalse(AppModel.shortLocalError(error).contains("RecipeError error 1"))
    }

    func testAggregateCatalogueCannotPromoteExperimentalRecipeToVerified() throws {
        var record = LocalProvisionalRecipe(apkSHA256: String(repeating: "a", count: 64), apkSize: 123,
            apkPath: "/tmp/synthetic.apk", title: "Synthetic", package: "com.Breach.LaserMatrix",
            versionName: "1.0.0", versionCode: "519", architectures: ["arm64-v8a"],
            nativeLibraries: ["lib/arm64-v8a/libunity.so", "lib/arm64-v8a/libmain.so"],
            assets: [], externalFileReferences: [], externalFiles: [], createdAt: Date())
        record.experimentalTarget = try LocalExperimentalTarget(appID: "8840783592704373",
            provenance: "https://avpplay.martek.de/api/v1/games/8840783592704373", analysis: record.genericAnalysis)
        let recipe = try XCTUnwrap(record.experimentalRecipe)
        let status = GameStatus(filesPresent: 0, filesRequired: 1, treesPresent: 0, treesRequired: 0,
            bytesToDownload: 0, userProvidedMissing: [], onDevice: .unknown, builtWith: nil)
        let data = Data(#"{"appId":"8840783592704373","title":"Synthetic","package":"com.Breach.LaserMatrix","status":"verified","works":1,"problems":0,"fails":0}"#.utf8)
        var catalog = try JSONDecoder().decode(CatalogGame.self, from: data)
        var game = Game(recipe: recipe, status: status, cover: nil, catalog: catalog)
        XCTAssertEqual(String(describing: game.trust), "untested")
        catalog.status = "incompatible"; game.catalog = catalog
        XCTAssertEqual(String(describing: game.trust), "incompatible")
    }
}
