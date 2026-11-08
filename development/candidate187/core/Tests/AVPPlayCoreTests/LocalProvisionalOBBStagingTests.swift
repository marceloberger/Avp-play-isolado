import XCTest
@testable import AVPPlayCore

final class LocalProvisionalOBBStagingTests: XCTestCase {
    private let obbDirectory = "android-files/Android/obb/com.XrealGames.Zc15"

    private func fixture(_ root: URL, obbNames: [String]) throws
        -> (LocalProvisionalRecipeStore, LocalProvisionalRecipe, LocalAPKVariant, Recipe, [URL]) {
        let target = try XCTUnwrap(CommunityKleptonTarget.candidate(package: "com.XrealGames.Zc15",
            versionCode: "1173", versionName: "2.0.1173-S-80237"))
        let externalRoot = root.appendingPathComponent("external", isDirectory: true)
        let provisionalRoot = root.appendingPathComponent("provisional-recipes", isDirectory: true)
        try FileManager.default.createDirectory(at: externalRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: provisionalRoot, withIntermediateDirectories: true)

        let apkHash = String(repeating: "a", count: 64)
        var files: [LocalProvisionalRecipe.ExternalFile] = []
        var sources: [URL] = []
        for (index, name) in obbNames.enumerated() {
            let source = externalRoot.appendingPathComponent(name)
            try Data(repeating: UInt8(index + 1), count: 128 + index).write(to: source)
            sources.append(source)
            files.append(.init(path: source.standardizedFileURL.path,
                               size: Int64(128 + index), sha256: try Hashing.sha256(of: source)))
        }
        let record = LocalProvisionalRecipe(apkSHA256: apkHash, apkSize: 900,
            apkPath: "/external/base.apk", title: target.title, package: target.packageID,
            versionName: target.versionName, versionCode: target.versionCode,
            architectures: ["arm64-v8a"], nativeLibraries: ["lib/arm64-v8a/libUE4.so"],
            assets: [], externalFileReferences: [], externalFiles: files,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000), communityTarget: target)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: provisionalRoot.appendingPathComponent(record.id + ".json"))

        let recipe = try XCTUnwrap(record.communityRecipe)
        let variant = LocalAPKVariant(id: "community-6072194326150034-1173-aaaaaaaaaaaa",
            recipeID: recipe.id, recipeVersionCode: 1173, relativePath: "unused/base.apk", size: 900,
            sha256: apkHash, package: target.packageID, versionCode: target.versionCode,
            versionName: target.versionName, architectures: ["arm64-v8a"],
            certificateSubjectObserved: nil, androidSignature: nil, source: "local",
            trustStatus: "local-unverified", official: false, recipeValidated: false, assets: [],
            sourceRootPath: "/external", originalAPKSourcePath: record.apkPath,
            packageMatchesRecipe: true, versionMatchesRecipe: true,
            officialAPKHashMatchesRecipe: false, missingRequiredFiles: [],
            registeredAt: Date(timeIntervalSince1970: 1_700_000_000))
        return (LocalProvisionalRecipeStore(root: provisionalRoot), record, variant, recipe, sources)
    }

    func testStagesMultipleOBBsWithOriginalNamesInRuntimeDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let names = ["main.1173.com.XrealGames.Zc15.obb", "patch.1173.com.XrealGames.Zc15.obb",
                     "overflow1.1173.com.XrealGames.Zc15.obb", "overflow2.1173.com.XrealGames.Zc15.obb",
                     "overflow3.1173.com.XrealGames.Zc15.obb", "overflow4.1173.com.XrealGames.Zc15.obb"]
        let (store, _, variant, recipe, _) = try fixture(root, obbNames: names)
        let entries = try store.installationOBBs(variant: variant, recipe: recipe, obbDirectory: obbDirectory)
        XCTAssertEqual(entries.count, 6)
        XCTAssertEqual(entries.map { URL(fileURLWithPath: $0.destination).lastPathComponent }, names.sorted())
        XCTAssertEqual(Set(entries.map { ($0.destination as NSString).deletingLastPathComponent }),
                       ["Documents/\(obbDirectory)"])
        XCTAssertTrue(entries.allSatisfy { $0.sha256.count == 64 && $0.size > 0 })
    }

    func testRejectsMissingOBBAndDoesNotTreatItAsOptional() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, _, variant, recipe, sources) = try fixture(root, obbNames: ["main.1173.com.XrealGames.Zc15.obb"])
        try FileManager.default.removeItem(at: try XCTUnwrap(sources.first))
        XCTAssertThrowsError(try store.installationOBBs(variant: variant, recipe: recipe, obbDirectory: obbDirectory)) {
            XCTAssertTrue("\($0)".contains("OBB associado ausente"))
        }
    }

    func testRejectsChangedOBBBytesAgainstRecordedSHA256() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, _, variant, recipe, sources) = try fixture(root, obbNames: ["main.1173.com.XrealGames.Zc15.obb"])
        try Data(repeating: 0xff, count: 128).write(to: try XCTUnwrap(sources.first))
        XCTAssertThrowsError(try store.installationOBBs(variant: variant, recipe: recipe, obbDirectory: obbDirectory)) {
            XCTAssertTrue("\($0)".contains("SHA-256 do OBB main.1173.com.XrealGames.Zc15.obb diverge"))
        }
    }

    func testRejectsOBBWithoutPreviouslyRecordedSHA256() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, _, variant, recipe, _) = try fixture(root, obbNames: ["main.1173.com.XrealGames.Zc15.obb"])
        let recordURL = store.root.appendingPathComponent("provisional-\(variant.sha256).json")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var record = try decoder.decode(LocalProvisionalRecipe.self, from: Data(contentsOf: recordURL))
        record.externalFiles[0].sha256 = nil
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: recordURL)
        XCTAssertThrowsError(try store.installationOBBs(variant: variant, recipe: recipe, obbDirectory: obbDirectory)) {
            XCTAssertTrue("\($0)".contains("não tem um SHA-256 registrado"))
        }
    }

    func testRejectsUnsafeFilenameAndWrongRuntimeDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, _, variant, recipe, _) = try fixture(root, obbNames: ["main.1173.com.XrealGames.Zc15.obb"])
        XCTAssertThrowsError(try store.installationOBBs(variant: variant, recipe: recipe, obbDirectory: "android-files/obb"))

        let recordURL = store.root.appendingPathComponent("provisional-\(variant.sha256).json")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var record = try decoder.decode(LocalProvisionalRecipe.self, from: Data(contentsOf: recordURL))
        record.externalFiles[0].path = record.externalFiles[0].path + "/../escape.obb"
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: recordURL)
        XCTAssertThrowsError(try store.installationOBBs(variant: variant, recipe: recipe, obbDirectory: obbDirectory))
    }

    func testOfficialRecipeNeverConsumesProvisionalOBBMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, _, localVariant, localRecipe, _) = try fixture(root, obbNames: ["main.1173.com.XrealGames.Zc15.obb"])
        var official = localRecipe
        official.id = "store-6072194326150034"
        official.files[0].id = "official-apk-id"
        let variant = localVariant
        XCTAssertTrue(try store.installationOBBs(variant: variant, recipe: official,
                                                  obbDirectory: obbDirectory).isEmpty)
    }
}
