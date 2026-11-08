import XCTest
@testable import AVPPlayApp
@testable import AVPPlayCore

final class LocalCommunitySelectionTests: XCTestCase {
    private struct PreparationReceiptFixture: Codable {
        let schema: Int
        let recipe: String
        let metadata: String
        let files: [SHA256FileCache.Identity]
    }

    private struct Fixture {
        let root: URL
        let record: LocalProvisionalRecipe
        let recipe: Recipe
        let store: LocalAPKVariantStore
        let variants: [LocalAPKVariant]
    }

    func testSavedProvisionalSelectionRestoresExactValidatedCommunityVariant() throws {
        let fixture = try makeFixture()
        let result = LocalCommunitySelectionRestoration.resolve(savedRecipeID: fixture.record.id,
            explicitlySelected: false, provisionalRecords: [fixture.record], recipes: [fixture.recipe],
            variants: fixture.store)
        guard case .restored(let choice) = result else { return XCTFail("Expected validated community restoration, got \(result)") }
        XCTAssertEqual(choice.recipeID, fixture.recipe.id)
        XCTAssertEqual(choice.variantID, fixture.variants[0].id)
        XCTAssertEqual(fixture.store.variants(for: fixture.recipe).count, 1)
    }

    func testExplicitProvisionalSelectionRemainsAvailableForInspection() throws {
        let fixture = try makeFixture()
        XCTAssertEqual(LocalCommunitySelectionRestoration.resolve(savedRecipeID: fixture.record.id,
            explicitlySelected: true, provisionalRecords: [fixture.record], recipes: [fixture.recipe],
            variants: fixture.store), .unchanged)
    }

    func testMultipleExactCommunityVariantsRequireExplicitChoice() throws {
        let fixture = try makeFixture(variantCount: 2)
        let result = LocalCommunitySelectionRestoration.resolve(savedRecipeID: fixture.record.id,
            explicitlySelected: false, provisionalRecords: [fixture.record], recipes: [fixture.recipe],
            variants: fixture.store)
        guard case .choose(let choices, _) = result else { return XCTFail("Expected explicit variant choice, got \(result)") }
        XCTAssertEqual(Set(choices.map(\.variantID)), Set(fixture.variants.map(\.id)))
    }

    func testMissingOrStaleValidationReceiptDoesNotRestoreAutomatically() throws {
        let fixture = try makeFixture(writeReceipt: false)
        let result = LocalCommunitySelectionRestoration.resolve(savedRecipeID: fixture.record.id,
            explicitlySelected: false, provisionalRecords: [fixture.record], recipes: [fixture.recipe],
            variants: fixture.store)
        guard case .verifyAgain = result else { return XCTFail("Expected validation gate, got \(result)") }
    }

    func testAPKHashAndSizeMustMatchTheProvisionalIdentity() throws {
        let fixture = try makeFixture()
        // A different provisional APK digest cannot select the previously validated variant.
        let mismatched = LocalProvisionalRecipe(apkSHA256: String(repeating: "f", count: 64),
            apkSize: fixture.record.apkSize, apkPath: fixture.record.apkPath, title: fixture.record.title,
            package: fixture.record.package, versionName: fixture.record.versionName,
            versionCode: fixture.record.versionCode, architectures: fixture.record.architectures,
            nativeLibraries: fixture.record.nativeLibraries, assets: fixture.record.assets,
            externalFileReferences: fixture.record.externalFileReferences, externalFiles: [],
            createdAt: fixture.record.createdAt, communityTarget: fixture.record.communityTarget)
        let mismatchResult = LocalCommunitySelectionRestoration.resolve(savedRecipeID: mismatched.id,
            explicitlySelected: false, provisionalRecords: [mismatched], recipes: [fixture.recipe], variants: fixture.store)
        guard case .choose = mismatchResult else { return XCTFail("A same-version different APK requires explicit selection, got \(mismatchResult)") }
        let wrongSize = LocalProvisionalRecipe(apkSHA256: fixture.record.apkSHA256,
            apkSize: fixture.record.apkSize + 1, apkPath: fixture.record.apkPath, title: fixture.record.title,
            package: fixture.record.package, versionName: fixture.record.versionName,
            versionCode: fixture.record.versionCode, architectures: fixture.record.architectures,
            nativeLibraries: fixture.record.nativeLibraries, assets: fixture.record.assets,
            externalFileReferences: fixture.record.externalFileReferences, externalFiles: [],
            createdAt: fixture.record.createdAt, communityTarget: fixture.record.communityTarget)
        let sizeResult = LocalCommunitySelectionRestoration.resolve(savedRecipeID: wrongSize.id,
            explicitlySelected: false, provisionalRecords: [wrongSize], recipes: [fixture.recipe], variants: fixture.store)
        guard case .choose = sizeResult else { return XCTFail("A size mismatch requires explicit selection, got \(sizeResult)") }
    }

    func testPackageOrVersionMismatchDoesNotRestoreACommunityRecipe() throws {
        let fixture = try makeFixture()
        let wrongPackage = LocalProvisionalRecipe(apkSHA256: fixture.record.apkSHA256,
            apkSize: fixture.record.apkSize, apkPath: fixture.record.apkPath, title: fixture.record.title,
            package: "different.package", versionName: fixture.record.versionName,
            versionCode: fixture.record.versionCode, architectures: fixture.record.architectures,
            nativeLibraries: fixture.record.nativeLibraries, assets: fixture.record.assets,
            externalFileReferences: fixture.record.externalFileReferences, externalFiles: [],
            createdAt: fixture.record.createdAt, communityTarget: fixture.record.communityTarget)
        XCTAssertEqual(LocalCommunitySelectionRestoration.resolve(savedRecipeID: wrongPackage.id,
            explicitlySelected: false, provisionalRecords: [wrongPackage], recipes: [fixture.recipe],
            variants: fixture.store), .unchanged)
        let wrongVersion = LocalProvisionalRecipe(apkSHA256: fixture.record.apkSHA256,
            apkSize: fixture.record.apkSize, apkPath: fixture.record.apkPath, title: fixture.record.title,
            package: fixture.record.package, versionName: fixture.record.versionName,
            versionCode: "999", architectures: fixture.record.architectures,
            nativeLibraries: fixture.record.nativeLibraries, assets: fixture.record.assets,
            externalFileReferences: fixture.record.externalFileReferences, externalFiles: [],
            createdAt: fixture.record.createdAt, communityTarget: fixture.record.communityTarget)
        XCTAssertEqual(LocalCommunitySelectionRestoration.resolve(savedRecipeID: wrongVersion.id,
            explicitlySelected: false, provisionalRecords: [wrongVersion], recipes: [fixture.recipe],
            variants: fixture.store), .unchanged)
    }

    func testOfficialRecipeIsNeverReclassifiedAsCommunity() throws {
        let fixture = try makeFixture()
        var official = fixture.recipe
        official.files[0].id = "official-apk"
        let result = LocalCommunitySelectionRestoration.resolve(savedRecipeID: fixture.record.id,
            explicitlySelected: false, provisionalRecords: [fixture.record], recipes: [official], variants: fixture.store)
        XCTAssertEqual(result, .unchanged)
        XCTAssertEqual(official.files[0].id, "official-apk")
    }

    private func makeFixture(variantCount: Int = 1, writeReceipt: Bool = true) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("community-selection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let target = try XCTUnwrap(CommunityKleptonTarget.known.first)
        let apkBytes = Data("verified local fixture APK bytes".utf8)
        let apkHash = Hashing.sha256(of: apkBytes)
        let externalAPK = root.appendingPathComponent("base.apk")
        try apkBytes.write(to: externalAPK)
        var record = LocalProvisionalRecipe(apkSHA256: apkHash, apkSize: Int64(apkBytes.count),
            apkPath: externalAPK.path, title: target.title, package: target.packageID,
            versionName: target.versionName, versionCode: target.versionCode, architectures: ["arm64-v8a"],
            nativeLibraries: ["lib/arm64-v8a/libUE4.so"], assets: [], externalFileReferences: [],
            externalFiles: [], createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        record.communityTarget = target
        let recipe = try XCTUnwrap(record.communityRecipe)
        let store = LocalAPKVariantStore(root: root.appendingPathComponent("local-variants", isDirectory: true))
        let directory = store.root.appendingPathComponent("\(recipe.id)-\(recipe.versionCode)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var variants: [LocalAPKVariant] = []
        for index in 0..<variantCount {
            let id = "\(recipe.id)-fixture\(index)"
            let relativePath = "\(recipe.id)-\(recipe.versionCode)/\(id).apk"
            let file = store.root.appendingPathComponent(relativePath)
            try apkBytes.write(to: file)
            let variant = LocalAPKVariant(id: id, recipeID: recipe.id, recipeVersionCode: recipe.versionCode,
                relativePath: relativePath, size: Int64(apkBytes.count), sha256: apkHash,
                package: target.packageID, versionCode: target.versionCode, versionName: target.versionName,
                architectures: ["arm64-v8a"], androidSignature: AndroidAPKSignature(state: "verified",
                    subject: "fixture", fingerprint: "fixture", detail: "fixture verified"),
                source: "local", trustStatus: "local-unverified", official: false, recipeValidated: false,
                assets: [], sourceRootPath: root.path, originalAPKSourcePath: externalAPK.path,
                packageMatchesRecipe: true, versionMatchesRecipe: true, officialAPKHashMatchesRecipe: false,
                missingRequiredFiles: [], registeredAt: Date(timeIntervalSince1970: 1_700_000_000))
            let metadata = try JSONEncoder().encode(variant)
            try metadata.write(to: directory.appendingPathComponent(id + ".json"))
            let cachedHash = try store.hashCache.digest(file)
            XCTAssertEqual(cachedHash, apkHash)
            variants.append(variant)
            if writeReceipt {
                let identity = try SHA256FileCache.identity(file)
                guard identity.reliable else { throw XCTSkip("Preparation receipt reuse fixture requires reliable APFS identity") }
                let validation = PreparationReceiptFixture(schema: 1,
                    recipe: try LocalAPKBuildEvidence.recipeHash(KleptonRecipeCompatibility.resolve(recipe)),
                    metadata: Hashing.sha256(of: metadata), files: [identity])
                let receiptDir = store.root.appendingPathComponent(".preparation-validations", isDirectory: true)
                try FileManager.default.createDirectory(at: receiptDir, withIntermediateDirectories: true)
                try JSONEncoder().encode(validation).write(to: receiptDir.appendingPathComponent(id + ".json"))
            }
        }
        return Fixture(root: root, record: record, recipe: recipe, store: store, variants: variants)
    }
}
