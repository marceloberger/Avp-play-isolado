import XCTest
@testable import AVPPlayCore

final class LocalProvisionalRecipeTests: XCTestCase {
    private func fixture(root: URL) -> LocalProvisionalRecipe {
        LocalProvisionalRecipe(apkSHA256: String(repeating: "a", count: 64), apkSize: 128,
            apkPath: "/external/Game.apk", title: "com.example.quest", package: "com.example.quest",
            versionName: "1.0", versionCode: "7", architectures: ["arm64-v8a"],
            nativeLibraries: ["lib/arm64-v8a/libgame.so"], assets: ["assets/data.bin"],
            externalFileReferences: [], externalFiles: [.init(path: "/Volumes/Game/main.obb", size: 4096)], createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testProvisionalFactsPersistWithoutCreatingOfficialRecipe() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("provisional-recipes"), withIntermediateDirectories: true)
        let store = LocalProvisionalRecipeStore(root: root.appendingPathComponent("provisional-recipes"))
        let record = fixture(root: root)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: store.root.appendingPathComponent(record.id + ".json"))
        let loaded = try store.loadAll()
        XCTAssertEqual(loaded, [record])
        XCTAssertEqual(loaded.first?.externalFiles.first?.path, "/Volumes/Game/main.obb")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("official-recipes/\(record.id).json").path))
    }

    func testMissingKleptonEvidenceBlocksBuildAndInstallActions() {
        let record = fixture(root: FileManager.default.temporaryDirectory)
        XCTAssertTrue(record.compatibilityBlockers.contains("Receita Klepton compatível e target verificados"))
        XCTAssertTrue(record.compatibilityBlockers.contains("Mapeamento de entrypoint e bibliotecas exigidas pela toolchain"))
        XCTAssertFalse(record.compatibilityBlockers.isEmpty)
    }

    func testArchitectureBlockerDoesNotInferArm64() {
        var record = fixture(root: FileManager.default.temporaryDirectory)
        record = LocalProvisionalRecipe(apkSHA256: record.apkSHA256, apkSize: record.apkSize, apkPath: record.apkPath,
            title: record.title, package: record.package, versionName: record.versionName, versionCode: record.versionCode,
            architectures: ["armeabi-v7a"], nativeLibraries: record.nativeLibraries, assets: record.assets,
            externalFileReferences: record.externalFileReferences, externalFiles: record.externalFiles, createdAt: record.createdAt)
        XCTAssertTrue(record.compatibilityBlockers.contains("APK com arquitetura arm64-v8a"))
    }

    func testZeroCaliber2RequiresExactPackageAndCatalogVersion() {
        let exact = CommunityKleptonTarget.candidate(package: "com.XrealGames.Zc15", versionCode: "1173",
                                                       versionName: "2.0.1173-S-80237")
        XCTAssertEqual(exact?.target, "x6072194326150034")
        XCTAssertEqual(exact?.status, "community")
        XCTAssertNil(CommunityKleptonTarget.candidate(package: "com.XrealGames.ZcReloaded", versionCode: "1173",
                                                        versionName: "2.0.1173-S-80237"))
        XCTAssertNil(CommunityKleptonTarget.candidate(package: "com.XrealGames.Zc15", versionCode: "1172",
                                                        versionName: "2.0.1173-S-80237"))
        XCTAssertNil(CommunityKleptonTarget.candidate(package: "com.XrealGames.Zc15", versionCode: "1173",
                                                        versionName: "different build"))
    }

    func testCommunityTargetRequiresGenericUE4InputsButNotAnAssumedOBB() {
        let target = try! XCTUnwrap(CommunityKleptonTarget.candidate(package: "com.XrealGames.Zc15",
            versionCode: "1173", versionName: "2.0.1173-S-80237"))
        var record = fixture(root: FileManager.default.temporaryDirectory)
        record = LocalProvisionalRecipe(apkSHA256: record.apkSHA256, apkSize: record.apkSize,
            apkPath: record.apkPath, title: "Zero Caliber 2", package: target.packageID,
            versionName: target.versionName, versionCode: target.versionCode,
            architectures: ["arm64-v8a"], nativeLibraries: ["lib/arm64-v8a/libUE4.so"],
            assets: [], externalFileReferences: [], externalFiles: [], createdAt: record.createdAt,
            communityTarget: target)
        XCTAssertTrue(record.genericTargetCanPrepareAndBuild)
        XCTAssertTrue(record.compatibilityBlockers.isEmpty)
        let runtimeRecipe = try! XCTUnwrap(record.communityRecipe)
        XCTAssertEqual(runtimeRecipe.toolchain.target, "x6072194326150034")
        XCTAssertEqual(runtimeRecipe.toolchain.minCommit, "a61188d")
        XCTAssertEqual(runtimeRecipe.status.playability, "untested")
        XCTAssertNil(runtimeRecipe.files.first?.sha256, "community identity must not become an asserted official APK hash")
        XCTAssertEqual(runtimeRecipe.files.first?.localName, "x6072194326150034.apk")
        record = LocalProvisionalRecipe(apkSHA256: record.apkSHA256, apkSize: record.apkSize,
            apkPath: record.apkPath, title: record.title, package: record.package,
            versionName: record.versionName, versionCode: record.versionCode,
            architectures: record.architectures, nativeLibraries: [], assets: record.assets,
            externalFileReferences: record.externalFileReferences, externalFiles: record.externalFiles,
            createdAt: record.createdAt, communityTarget: target)
        XCTAssertFalse(record.genericTargetCanPrepareAndBuild)
        XCTAssertTrue(record.compatibilityBlockers.contains(where: { $0.contains("libUE4.so") }))
    }

    func testCommunityConfigurationPersistsAsLocalProvenance() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalProvisionalRecipeStore(root: root.appendingPathComponent("provisional-recipes"))
        let target = try XCTUnwrap(CommunityKleptonTarget.candidate(package: "com.XrealGames.Zc15",
            versionCode: "1173", versionName: "2.0.1173-S-80237"))
        var record = fixture(root: root)
        record = LocalProvisionalRecipe(apkSHA256: record.apkSHA256, apkSize: record.apkSize,
            apkPath: record.apkPath, title: target.title, package: target.packageID,
            versionName: target.versionName, versionCode: target.versionCode,
            architectures: ["arm64-v8a"], nativeLibraries: ["lib/arm64-v8a/libUE4.so"],
            assets: [], externalFileReferences: [], externalFiles: [], createdAt: record.createdAt,
            communityTarget: target)
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: store.root.appendingPathComponent(record.id + ".json"))
        let loaded = try XCTUnwrap(store.loadAll().first)
        XCTAssertEqual(loaded.communityTarget, target)
        XCTAssertEqual(loaded.communityTarget?.provenance, target.provenance)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("official-recipes").path))
    }
}
