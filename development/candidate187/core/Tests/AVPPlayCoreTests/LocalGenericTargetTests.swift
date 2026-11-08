import XCTest
@testable import AVPPlayCore

final class LocalGenericTargetTests: XCTestCase {
    private func inspection(_ libraries: [String], architectures: Set<String> = ["arm64-v8a"],
                            nativeActivity: Bool = false, entrypoint: String? = nil) -> ApkUnpacker.Inspection {
        .init(package: "com.example.experimental", versionCode: "42", versionName: "1.2",
              architectures: architectures, files: libraries.count, nativeLibraries: libraries,
              hasNativeActivity: nativeActivity, nativeActivityLibrary: entrypoint)
    }

    func testRecognizesOnlyKlepton824GenericEngineShapesAndRealEntrypoints() {
        let cases: [([String], LocalGenericEngine, String)] = [
            (["lib/arm64-v8a/libUE4.so"], .unreal4, "libUE4"),
            (["lib/arm64-v8a/libUnreal.so"], .unreal, "libUnreal"),
            (["lib/arm64-v8a/libil2cpp.so", "lib/arm64-v8a/libmain.so"], .unity, "libmain"),
            (["lib/arm64-v8a/libSDL2.so", "lib/arm64-v8a/libmain.so"], .sdl2, "libmain")
        ]
        for (libraries, engine, entrypoint) in cases {
            let analysis = LocalGenericTargetAnalysis.inspect(inspection(libraries))
            XCTAssertTrue(analysis.canAttemptGenericBuild, "\(libraries)")
            XCTAssertEqual(analysis.engine, engine)
            XCTAssertEqual(analysis.entrypoint, entrypoint)
        }
        let native = LocalGenericTargetAnalysis.inspect(inspection(
            ["lib/arm64-v8a/libcustom.so"], nativeActivity: true, entrypoint: "custom"))
        XCTAssertTrue(native.canAttemptGenericBuild)
        XCTAssertEqual(native.engine, .nativeActivity)
        XCTAssertEqual(native.entrypoint, "libcustom")
    }

    func testNativeActivityLibraryNameIsReadOnlyFromExplicitManifestMetadata() {
        let manifest = #"<manifest><application><activity android:name="com.example.GameActivity"/><meta-data android:name="android.app.lib_name" android:value="libGame"/></application></manifest>"#
        XCTAssertEqual(ApkUnpacker.manifestValue("android.app.lib_name", in: manifest), "libGame")
        XCTAssertNil(ApkUnpacker.manifestValue("com.example.other", in: manifest))
    }

    func testRejectsWrongArchitectureUnknownEngineAndMissingEntrypoint() {
        let wrongArchitecture = LocalGenericTargetAnalysis.inspect(inspection(
            ["lib/armeabi-v7a/libUE4.so"], architectures: ["armeabi-v7a"]))
        XCTAssertFalse(wrongArchitecture.canAttemptGenericBuild)
        XCTAssertTrue(wrongArchitecture.blockers.contains { $0.contains("arm64-v8a") })

        let unknown = LocalGenericTargetAnalysis.inspect(inspection(["lib/arm64-v8a/libgame.so"]))
        XCTAssertFalse(unknown.canAttemptGenericBuild)

        let missingMain = LocalGenericTargetAnalysis.inspect(inspection(["lib/arm64-v8a/libil2cpp.so"]))
        XCTAssertFalse(missingMain.canAttemptGenericBuild)
        XCTAssertTrue(missingMain.blockers.contains { $0.contains("libmain.so") })
    }

    func testAppIDIsExplicitAndNewRecipeUsesPermitted850Profile() throws {
        let analysis = LocalGenericTargetAnalysis.inspect(inspection(["lib/arm64-v8a/libUE4.so"]))
        XCTAssertThrowsError(try LocalExperimentalTarget(appID: "com.example.experimental", provenance: "package", analysis: analysis))
        XCTAssertThrowsError(try LocalExperimentalTarget(appID: "123456", provenance: "", analysis: analysis))
        XCTAssertThrowsError(try LocalExperimentalTarget(appID: "123456", provenance: "https://example.invalid/store/123456", analysis: .init(
            engine: nil, entrypoint: nil, nativeLibraries: [], blockers: ["unknown"])))

        let target = try LocalExperimentalTarget(appID: "123456", provenance: "User provided official store URL", analysis: analysis)
        var record = LocalProvisionalRecipe(apkSHA256: String(repeating: "a", count: 64), apkSize: 99,
            apkPath: "/tmp/game.apk", title: "Example", package: "com.example.experimental", versionName: "1.2",
            versionCode: "42", architectures: ["arm64-v8a"], nativeLibraries: ["lib/arm64-v8a/libUE4.so"],
            assets: [], externalFileReferences: [], externalFiles: [], createdAt: Date(timeIntervalSince1970: 1))
        record.experimentalTarget = target
        let recipe = try XCTUnwrap(record.experimentalRecipe)
        XCTAssertEqual(recipe.toolchain.target, "x123456")
        XCTAssertEqual(recipe.toolchain.minCommit, "cc2856c")
        XCTAssertEqual(recipe.status.playability, "untested")
        XCTAssertNil(recipe.store.appId)
        XCTAssertThrowsError(try recipe.validate(), "generated recipes are not distributable catalog recipes")
        XCTAssertNoThrow(try recipe.validateForJob())
        let fakeToolchain = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fakeToolchain) }
        let vision = fakeToolchain.appendingPathComponent("visionos", isDirectory: true)
        try FileManager.default.createDirectory(at: vision, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: vision.appendingPathComponent("run.sh"))
        XCTAssertThrowsError(try Toolchain(root: fakeToolchain).buildOnly(recipe: recipe,
            store: ContentStore(root: fakeToolchain.appendingPathComponent("store")), bundleID: "io.example.test",
            workspaceRoot: fakeToolchain.appendingPathComponent("work"))) {
            XCTAssertTrue("\($0)".contains("Klepton 850 cc2856c + TLS168"), "unverified toolchain must fail closed")
        }
        var tampered = recipe
        tampered.toolchain.minCommit = "900daf8"
        XCTAssertThrowsError(try tampered.validateForJob())
    }

    func testExplicitManifestOBBReferenceBlocksRecipeUntilMatchingFileIsAssociated() throws {
        let analysis = LocalGenericTargetAnalysis.inspect(inspection(["lib/arm64-v8a/libUE4.so"]))
        let target = try LocalExperimentalTarget(appID: "123456", provenance: "documented source", analysis: analysis)
        var record = LocalProvisionalRecipe(apkSHA256: String(repeating: "c", count: 64), apkSize: 99,
            apkPath: "/tmp/game.apk", title: "Example", package: "com.example.experimental", versionName: "1.2",
            versionCode: "42", architectures: ["arm64-v8a"], nativeLibraries: ["lib/arm64-v8a/libUE4.so"],
            assets: [], externalFileReferences: [#"<meta-data android:value="/sdcard/Android/obb/com.example.experimental/main.42.obb"/>"#],
            externalFiles: [], createdAt: Date(timeIntervalSince1970: 1))
        record.experimentalTarget = target
        XCTAssertTrue(record.compatibilityBlockers.contains { $0.contains("main.42.obb") })
        XCTAssertNil(record.experimentalRecipe)
    }

    func testExternalOBBAssociationRecordsDigestAndEngineDestination() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalProvisionalRecipeStore(root: root.appendingPathComponent("provisionals"))
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        let record = LocalProvisionalRecipe(apkSHA256: String(repeating: "b", count: 64), apkSize: 99,
            apkPath: "/tmp/game.apk", title: "Example", package: "com.example.experimental", versionName: "1.2",
            versionCode: "42", architectures: ["arm64-v8a"], nativeLibraries: ["lib/arm64-v8a/libUE4.so"],
            assets: [], externalFileReferences: [], externalFiles: [], createdAt: Date(timeIntervalSince1970: 1))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: store.root.appendingPathComponent(record.id + ".json"))
        _ = try store.setExperimentalTarget(appID: "123456", provenance: "documented source", for: record.id)
        let obb = root.appendingPathComponent("main.42.com.example.experimental.obb")
        try Data("synthetic-obb".utf8).write(to: obb)
        let updated = try store.associate([obb], with: record.id)
        let external = try XCTUnwrap(updated.externalFiles.first)
        XCTAssertEqual(external.kind, "obb")
        XCTAssertEqual(external.destination, "android-files/Android/obb/com.example.experimental")
        XCTAssertEqual(external.sha256, try Hashing.sha256(of: obb))
        XCTAssertTrue(external.isSafeForExperimentalRecipe)
    }

    func testFull824ReceiptVerifiesAll2109FilesAndRejectsTampering() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let vision = root.appendingPathComponent("visionos", isDirectory: true)
        let sources = vision.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let critical: [String: Data] = [
            "Makefile": Data("make".utf8),
            "visionos/run.sh": Data("#!/bin/sh\n".utf8),
            "visionos/targets.py": Data("targets".utf8),
            "visionos/gen_xcodeproj.py": Data("generator".utf8),
            "visionos/Sources/kl_app.c": Data("int main(void) { return 0; }".utf8)
        ]
        for (path, bytes) in critical {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
        }
        let toolchainManifest = """
        {"format":1,"version":824,"commit":"a61188d","ancestors":["a61188d"],"created":"2026-10-31T00:00:00Z","modified":false}
        """
        try Data(toolchainManifest.utf8).write(to: root.appendingPathComponent("toolchain.json"))
        var expected: [String: String] = [:]
        let criticalPaths = Array(critical.keys) + ["toolchain.json"]
        for path in criticalPaths { expected[path] = try Hashing.sha256(of: root.appendingPathComponent(path)) }
        for index in 0..<2103 {
            let path = "fixture/file-\(index).dat"
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = Data("fixture-\(index)".utf8)
            try data.write(to: url)
            expected[path] = Hashing.sha256(of: data)
        }
        XCTAssertEqual(expected.count, 2109)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(expected).write(to: root.appendingPathComponent(".isolated-source-sha256.json"))
        let toolchain = try Toolchain(root: root)
        XCTAssertEqual(try OptionalRuntime824.verifyFullIntegrity(of: toolchain), 2109)
        // Reproduce the installed 166 runtime: intact payload plus a legacy prepared game.
        let legacy = root.appendingPathComponent("x123456/AndroidManifest.xml")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("legacy game".utf8).write(to: legacy)
        XCTAssertThrowsError(try OptionalRuntime824.verifyFullIntegrity(of: toolchain)) { error in
            XCTAssertTrue(error.localizedDescription.contains("AndroidManifest.xml"))
            XCTAssertFalse(error.localizedDescription.contains("RecipeError error"))
        }
        let staged = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staged) }
        try OptionalRuntime824.stageVerifiedPayload(from: toolchain, to: staged)
        XCTAssertEqual(try OptionalRuntime824.verifyFullIntegrity(of: Toolchain(root: staged)), 2109)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.appendingPathComponent("x123456").path))
        XCTAssertEqual(try Data(contentsOf: legacy), Data("legacy game".utf8))
        try Data("tampered".utf8).write(to: root.appendingPathComponent("fixture/file-0.dat"))
        let rejected = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(try OptionalRuntime824.stageVerifiedPayload(from: toolchain, to: rejected))
        XCTAssertFalse(FileManager.default.fileExists(atPath: rejected.path))
        try FileManager.default.removeItem(at: root.appendingPathComponent("fixture/file-0.dat"))
        XCTAssertThrowsError(try OptionalRuntime824.stageVerifiedPayload(from: toolchain, to: rejected))
        XCTAssertFalse(FileManager.default.fileExists(atPath: rejected.path))

        XCTAssertThrowsError(try OptionalRuntime824.verifyFullIntegrity(of: toolchain))
    }
}
