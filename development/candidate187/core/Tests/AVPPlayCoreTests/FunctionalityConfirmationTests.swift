import XCTest
@testable import AVPPlayCore

final class FunctionalityConfirmationTests: XCTestCase {
    func fixture() throws -> (Recipe, LocalAPKVariant, LocalAPKLearningStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("functionality-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let recipes = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("recipes")
        let recipe = try RecipeStore(directory: recipes).load(id: "batman")
        let variant = LocalAPKVariant(id: "fixture", recipeID: recipe.id, recipeVersionCode: recipe.versionCode,
            relativePath: "fixture.apk", size: 123, sha256: String(repeating: "a", count: 64), package: recipe.package,
            versionCode: String(recipe.versionCode), architectures: ["arm64-v8a"], source: "local",
            trustStatus: "local-unverified", official: false, recipeValidated: false, registeredAt: Date())
        let store = LocalAPKLearningStore(variants: LocalAPKVariantStore(root: root))
        try store.authorize(variant, recipe: recipe, allowed: true)
        return (recipe, variant, store)
    }
    func receipt(_ variant: LocalAPKVariant, recipe: Recipe, id: String = "installed", setting: String = "standard") throws -> LocalAPKInstallation {
        var request = InstallRequest(toolchain: "/fixture/klepton")
        request.localAPKVariantID = variant.id; request.bundleId = "test.game"; request.controllerMode = .standard
        request.device = "vision"; request.team = "TESTTEAM01"
        var result = LocalAPKInstallation(id: id, variantID: variant.id, sha256: variant.sha256, size: variant.size,
            package: variant.package, versionCode: variant.versionCode, bundleID: "test.game", deviceID: "vision",
            team: "TESTTEAM01", toolchain: "750-fixture", date: Date())
        result.gameTitle = recipe.title; result.recipeID = recipe.id
        result.configuration = request
        result.build = LocalAPKBuildEvidence(signedBuildSHA256: String(repeating: "b", count: 64),
            unsignedBuildSHA256: String(repeating: "c", count: 64), recipeSHA256: try LocalAPKBuildEvidence.recipeHash(recipe),
            assetsSHA256: try LocalAPKBuildEvidence.assetsHash(variant), settings: ["controller": setting])
        return result
    }
    func testHistoricalPresentationDoesNotConfirmChangedManifest135() throws {
        let (recipe, variant, store) = try fixture()
        var confirmed = try receipt(variant, recipe: recipe)
        confirmed.confirmedAt = Date(timeIntervalSince1970: 1234567)
        var record = try store.load(recipe)
        record.installations = [confirmed]
        let file = store.root.appendingPathComponent("\(recipe.id)-\(recipe.versionCode).json")
        try JSONEncoder().encode(record).write(to: file)
        let before = try Data(contentsOf: file)
        XCTAssertEqual(try store.confirmationPresentation(variant: variant, recipe: recipe), "Funcionamento confirmado")
        confirmed.build?.assetsSHA256 = String(repeating: "d", count: 64)
        record.installations = [confirmed]
        try JSONEncoder().encode(record).write(to: file)
        let historical = try Data(contentsOf: file)
        XCTAssertTrue(try store.latestInstallations(variant: variant, recipe: recipe).isEmpty)
        XCTAssertEqual(try store.confirmationPresentation(variant: variant, recipe: recipe), "Funcionamento confirmado anteriormente")
        XCTAssertThrowsError(try LocalAPKVariantStore.requireCompatibleDependencies(variant, recipe: recipe))
        XCTAssertEqual(try Data(contentsOf: file), historical)
        var other = variant; other.sha256 = String(repeating: "e", count: 64)
        XCTAssertNil(try store.confirmationPresentation(variant: other, recipe: recipe))
        confirmed.revokedAt = Date(); record.installations = [confirmed]
        try JSONEncoder().encode(record).write(to: file)
        XCTAssertNil(try store.confirmationPresentation(variant: variant, recipe: recipe))
        XCTAssertNotEqual(before, historical)
    }

    func testConfirmationPersistsFullIdentityAndRevocationDoesNotChangeIntegrityOrLearning() throws {
        let (recipe, variant, store) = try fixture(), receipt = try receipt(variant, recipe: recipe)
        try store.recordInstallation(receipt, variant: variant, recipe: recipe)
        XCTAssertNil(try store.load(recipe).installations[0].functionalityStatus)
        let confirmed = Date(timeIntervalSince1970: 1234567)
        try store.setFunctionality(receiptID: receipt.id, variant: variant, recipe: recipe, confirmed: true, now: confirmed)
        let reopened = LocalAPKLearningStore(variants: LocalAPKVariantStore(root: store.root.deletingLastPathComponent()))
        let saved = try reopened.load(recipe).installations[0]
        XCTAssertEqual(saved.confirmedAt, confirmed)
        XCTAssertEqual(saved.functionalityStatus, "funcionamento confirmado pelo usuário")
        XCTAssertEqual(saved.sha256, variant.sha256); XCTAssertEqual(saved.build, receipt.build)
        XCTAssertEqual(saved.gameTitle, recipe.title); XCTAssertEqual(saved.recipeID, recipe.id)
        XCTAssertEqual(saved.configuration, receipt.configuration)
        XCTAssertNil(try reopened.load(recipe).current, "Functionality must not silently authorize/learn a publisher hash")
        XCTAssertEqual(try reopened.confirmedConfiguration(receiptID: receipt.id, variant: variant, recipe: recipe), receipt.configuration)
        try reopened.setFunctionality(receiptID: receipt.id, variant: variant, recipe: recipe, confirmed: false)
        XCTAssertNil(try store.load(recipe).installations[0].functionalityStatus)
        XCTAssertEqual(try store.load(recipe).installations[0].confirmedAt, confirmed)
        XCTAssertThrowsError(try store.confirmedConfiguration(receiptID: receipt.id, variant: variant, recipe: recipe))
        XCTAssertEqual(try store.load(recipe).installations[0].sha256, variant.sha256)
    }
    func testChangedAPKConfigurationBuildAndNewInstallNeverInheritConfirmation() throws {
        let (recipe, variant, store) = try fixture(), first = try receipt(variant, recipe: recipe)
        try store.recordInstallation(first, variant: variant, recipe: recipe)
        try store.setFunctionality(receiptID: first.id, variant: variant, recipe: recipe, confirmed: true)
        var changed = variant; changed.sha256 = String(repeating: "d", count: 64)
        XCTAssertThrowsError(try store.setFunctionality(receiptID: first.id, variant: changed, recipe: recipe, confirmed: true))
        XCTAssertThrowsError(try store.confirmedConfiguration(receiptID: first.id, variant: changed, recipe: recipe))
        XCTAssertTrue(try store.latestInstallations(variant: changed, recipe: recipe).isEmpty)
        var second = try receipt(variant, recipe: recipe, id: "new-build", setting: "alternate")
        second.build?.signedBuildSHA256 = String(repeating: "e", count: 64)
        try store.recordInstallation(second, variant: variant, recipe: recipe)
        let current = try store.latestInstallations(variant: variant, recipe: recipe)
        XCTAssertEqual(current.map(\.id), [second.id]); XCTAssertNil(current[0].functionalityStatus)
        XCTAssertNotNil(try store.load(recipe).installations[0].functionalityStatus, "Keep historical testimony scoped to old build")
        // Even an identical reinstall needs a new explicit confirmation.
        let third = try receipt(variant, recipe: recipe, id: "identical-reinstall")
        try store.recordInstallation(third, variant: variant, recipe: recipe)
        XCTAssertNil(try store.latestInstallations(variant: variant, recipe: recipe)[0].functionalityStatus)
    }
    func testRecipeAssetsVariantAndDestinationBoundaries() throws {
        let (recipe, variant, store) = try fixture(), first = try receipt(variant, recipe: recipe)
        try store.recordInstallation(first, variant: variant, recipe: recipe)
        try store.setFunctionality(receiptID: first.id, variant: variant, recipe: recipe, confirmed: true)
        var changedRecipe = recipe; changedRecipe.toolchain.target += "changed"
        XCTAssertThrowsError(try store.confirmedConfiguration(receiptID: first.id, variant: variant, recipe: changedRecipe))
        var changedVariant = variant; changedVariant.assets = [.init(name: "new.obb", sourcePath: "/fixture", size: 1,
            sha256: String(repeating: "f", count: 64), recipeSizeMatches: true)]
        XCTAssertThrowsError(try store.confirmedConfiguration(receiptID: first.id, variant: changedVariant, recipe: recipe))
        XCTAssertTrue(try store.latestInstallations(variant: changedVariant, recipe: recipe).isEmpty)
        var other = try receipt(variant, recipe: recipe, id: "other-bundle"); other.bundleID = "test.other"; other.configuration?.bundleId = "test.other"
        try store.recordInstallation(other, variant: variant, recipe: recipe)
        let current = try store.latestInstallations(variant: variant, recipe: recipe)
        XCTAssertEqual(current.count, 2)
        XCTAssertNil(current.first { $0.bundleID == "test.other" }?.functionalityStatus)
        XCTAssertNotNil(current.first { $0.bundleID == "test.game" }?.functionalityStatus)
        changedVariant = variant; changedVariant.id = "another-variant"
        XCTAssertThrowsError(try store.setFunctionality(receiptID: first.id, variant: changedVariant, recipe: recipe, confirmed: true))
    }
    func testLegacyReceiptsRemainReadableWithoutInventingBuildSettingsOrConfirmation() throws {
        let (recipe, variant, store) = try fixture()
        var legacy = try receipt(variant, recipe: recipe); legacy.build = nil; legacy.configuration = nil
        try store.recordInstallation(legacy, variant: variant, recipe: recipe)
        let decoded = try JSONDecoder().decode(LocalAPKLearningRecord.self, from: JSONEncoder().encode(store.load(recipe)))
        XCTAssertEqual(decoded.installations.count, 1); XCTAssertNil(decoded.installations[0].confirmedAt)
        XCTAssertThrowsError(try store.setFunctionality(receiptID: legacy.id, variant: variant, recipe: recipe, confirmed: true))
        XCTAssertThrowsError(try store.setFunctionality(receiptID: "not-installed", variant: variant, recipe: recipe, confirmed: true))
    }
    func testNewBuildCannotImportConfirmationOrOverwriteHistoricalReceipt() throws {
        let (recipe, variant, store) = try fixture(), old = try receipt(variant, recipe: recipe)
        try store.recordInstallation(old, variant: variant, recipe: recipe)
        try store.setFunctionality(receiptID: old.id, variant: variant, recipe: recipe, confirmed: true)
        let saved = try store.load(recipe).installations[0]
        try store.recordInstallation(old, variant: variant, recipe: recipe) // Idempotent Resume preserves testimony.
        XCTAssertEqual(try store.load(recipe).installations[0], saved)
        var collision = old; collision.build?.unsignedBuildSHA256 = String(repeating: "f", count: 64)
        XCTAssertThrowsError(try store.recordInstallation(collision, variant: variant, recipe: recipe))
        var injected = saved; injected.id = "new-with-old-confirmation"
        XCTAssertThrowsError(try store.recordInstallation(injected, variant: variant, recipe: recipe))
        var next = try receipt(variant, recipe: recipe, id: "different-build")
        next.build?.unsignedBuildSHA256 = String(repeating: "d", count: 64)
        next.build?.signedBuildSHA256 = String(repeating: "e", count: 64)
        try store.recordInstallation(next, variant: variant, recipe: recipe)
        XCTAssertEqual(try store.load(recipe).installations[0], saved)
        XCTAssertNil(try store.latestInstallations(variant: variant, recipe: recipe)[0].functionalityStatus)
        var changedRecipe = recipe; changedRecipe.title += " changed"
        XCTAssertThrowsError(try store.setFunctionality(receiptID: next.id, variant: variant, recipe: changedRecipe, confirmed: true))
        XCTAssertNotNil(try store.load(recipe).installations[0].functionalityStatus)
        try store.setFunctionality(receiptID: old.id, variant: variant, recipe: changedRecipe, confirmed: false)
        XCTAssertNotNil(try store.load(recipe).installations[0].revokedAt)
    }

    func testRequiredOptionalAPKAndCompiledIdentitiesRemainIndependent() throws {
        var (recipe, variant, _) = try fixture()
        recipe.files = [RecipeFile(name: "required.obb", role: "obb", id: "r", required: true),
                        RecipeFile(name: "optional.obb", role: "obb", id: "o", required: false)]
        variant.assets = [LocalAPKAsset(name: "required.obb", sourcePath: "/r", size: 1, sha256: String(repeating: "a", count: 64), recipeSizeMatches: true),
                          LocalAPKAsset(name: "optional.obb", sourcePath: "/o", size: 2, sha256: String(repeating: "b", count: 64), recipeSizeMatches: true)]
        let selection = FetchSelection(optionalNames: ["optional.obb"])
        let required = try LocalAPKBuildEvidence.dependencyHash(variant, recipe: recipe, required: true, selection: selection)
        let optional = try LocalAPKBuildEvidence.dependencyHash(variant, recipe: recipe, required: false, selection: selection)
        variant.assets?[1].sha256 = String(repeating: "c", count: 64)
        XCTAssertEqual(required, try LocalAPKBuildEvidence.dependencyHash(variant, recipe: recipe, required: true, selection: selection))
        XCTAssertNotEqual(optional, try LocalAPKBuildEvidence.dependencyHash(variant, recipe: recipe, required: false, selection: selection))
        let empty = try LocalAPKBuildEvidence.dependencyHash(variant, recipe: recipe, required: false, selection: FetchSelection())
        XCTAssertNotEqual(empty, optional)
        var built = try receipt(variant, recipe: recipe)
        let originalAPK = built.sha256
        built.build?.unsignedBuildSHA256 = String(repeating: "d", count: 64)
        XCTAssertEqual(built.sha256, originalAPK)
        let compiled = built.build?.unsignedBuildSHA256
        built.build?.signedBuildSHA256 = String(repeating: "e", count: 64)
        XCTAssertEqual(built.build?.unsignedBuildSHA256, compiled)
    }

    func testCanonicalBuildIdentityIsIndependentOfDictionaryOrder() throws {
        XCTAssertEqual(try LocalAPKBuildEvidence.digest(["a": "1", "b": "2"]),
                       try LocalAPKBuildEvidence.digest(["b": "2", "a": "1"]))
        XCTAssertNotEqual(try LocalAPKBuildEvidence.digest(["controller": "standard"]),
                          try LocalAPKBuildEvidence.digest(["controller": "alternate"]))
    }
    func testInstalledDefaultsComeFromProductNotLaterPreferences() throws {
        let (recipe, variant, _) = try fixture()
        var evidence = try XCTUnwrap(receipt(variant, recipe: recipe).build)
        evidence.settings = ["Info.KLRoomGuardDefault": "0", "Info.KLGameLanguageDefault": "de", "Info.KLControllerModeDefault": "standard"]
        var current = InstallRequest(toolchain: "/fixture")
        current.roomMeasuring = true; current.gameLanguage = "en"
        let installed = evidence.applyingProductDefaults(to: current)
        XCTAssertEqual(installed.roomMeasuring, false); XCTAssertEqual(installed.gameLanguage, "de")
        XCTAssertEqual(installed.controllerMode, .standard)
    }

    func testConfirmedRecordCannotBypassFullHashValidationOrUseAuthorization() throws {
        let (recipe, original, store) = try fixture()
        let registry = LocalAPKVariantStore(root: store.root.deletingLastPathComponent())
        var variant = original
        let bytes = Data("fixture bytes".utf8)
        variant.sha256 = Hashing.sha256(of: bytes); variant.size = Int64(bytes.count)
        variant.relativePath = "\(recipe.id)-\(recipe.versionCode)/\(variant.sha256).apk"
        let apk = registry.root.appendingPathComponent(variant.relativePath)
        try FileManager.default.createDirectory(at: apk.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: apk)
        try JSONEncoder().encode(variant).write(to: apk.deletingLastPathComponent().appendingPathComponent(variant.id + ".json"))
        try store.authorize(variant, recipe: recipe, allowed: true)
        let installed = try receipt(variant, recipe: recipe)
        try store.recordInstallation(installed, variant: variant, recipe: recipe)
        try store.setFunctionality(receiptID: installed.id, variant: variant, recipe: recipe, confirmed: true)
        // Same length corruption must still fail before APK inspection; user testimony is never a hash override.
        try Data(repeating: 0, count: bytes.count).write(to: apk)
        XCTAssertThrowsError(try registry.validated(id: variant.id, for: recipe, forceFull: true)) { error in
            guard case LocalAPKVariantError.hashMismatch = error else { return XCTFail("Expected hash rejection, got \(error)") }
        }
        try store.authorize(variant, recipe: recipe, allowed: false)
        XCTAssertThrowsError(try store.requireAuthorized(variant, recipe: recipe))
        XCTAssertNotNil(try store.load(recipe).installations[0].functionalityStatus,
                        "User testimony is independent from authorization and integrity, never a replacement")
    }

    func testInstallationRejectsMismatchedBuildConfiguration() throws {
        let (recipe, variant, store) = try fixture()
        var wrong = try receipt(variant, recipe: recipe)
        wrong.configuration?.bundleId = "test.wrong"
        XCTAssertThrowsError(try store.recordInstallation(wrong, variant: variant, recipe: recipe))
        wrong = try receipt(variant, recipe: recipe); wrong.build?.signedBuildSHA256 = "truncated"
        XCTAssertThrowsError(try store.recordInstallation(wrong, variant: variant, recipe: recipe))
        XCTAssertTrue(try store.load(recipe).installations.isEmpty)
    }

    func testAtomicConfirmationSavesLocalHashAndRestorePreservesIt() throws {
        let (recipe, variant, store) = try fixture()
        let installed = try receipt(variant, recipe: recipe)
        try store.recordInstallation(installed, variant: variant, recipe: recipe)
        let now = Date(timeIntervalSince1970: 1234567)
        try store.setFunctionality(receiptID: installed.id, variant: variant, recipe: recipe,
                                   confirmed: true, now: now, saveConfirmedHash: true)
        let saved = try store.load(recipe)
        XCTAssertEqual(saved.current?.hashes[variant.sha256], variant.size)
        XCTAssertEqual(saved.current?.date, now)
        XCTAssertEqual(saved.installations[0].build, installed.build)
        XCTAssertEqual(saved.installations[0].configuration, installed.configuration)
        try store.restore(nil, recipe: recipe)
        XCTAssertEqual(try store.load(recipe).current?.hashes[variant.sha256], variant.size)
        XCTAssertEqual(try store.load(recipe).installations, saved.installations)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.root.appendingPathComponent("audit-backups").path))
    }

    func testFailedFreshVerificationCannotSaveConfirmationOrHash() throws {
        let (recipe, variant, store) = try fixture()
        let installed = try receipt(variant, recipe: recipe)
        try store.recordInstallation(installed, variant: variant, recipe: recipe)
        let registry = LocalAPKVariantStore(root: store.root.deletingLastPathComponent())
        XCTAssertThrowsError(try store.confirmVerifiedFunctionality(receiptID: installed.id, variant: variant,
                                                                   recipe: recipe, variants: registry))
        XCTAssertNil(try store.load(recipe).current)
        XCTAssertNil(try store.load(recipe).installations[0].confirmedAt)
    }

    func testDecliningHashKeepsConfirmationAndAllowsLaterSaveWithoutChangingTestimony() throws {
        let (recipe, variant, store) = try fixture()
        let installed = try receipt(variant, recipe: recipe)
        try store.recordInstallation(installed, variant: variant, recipe: recipe)
        let date = Date(timeIntervalSince1970: 12345)
        try store.setFunctionality(receiptID: installed.id, variant: variant, recipe: recipe,
                                   confirmed: true, now: date, saveConfirmedHash: false)
        let confirmed = try store.load(recipe).installations[0]
        XCTAssertNotNil(confirmed.functionalityStatus)
        XCTAssertNil(try store.load(recipe).current)
        try store.restore(nil, recipe: recipe)
        XCTAssertNil(try store.load(recipe).current?.hashes[variant.sha256], "Restore must honor Agora não")
        XCTAssertEqual(try store.load(recipe).installations[0], confirmed)
        try store.confirmLearning(variant, recipe: recipe, receiptID: installed.id)
        XCTAssertEqual(try store.load(recipe).installations[0], confirmed)
        XCTAssertEqual(try store.load(recipe).current?.hashes[variant.sha256], variant.size)
        try store.restore(nil, recipe: recipe)
        XCTAssertEqual(try store.load(recipe).current?.hashes[variant.sha256], variant.size)
    }

}
