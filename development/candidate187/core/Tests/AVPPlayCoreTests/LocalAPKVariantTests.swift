import XCTest
@testable import AVPPlayCore

final class LocalAPKVariantTests: XCTestCase {
    private func batmanRecipe() throws -> Recipe {
        let recipes = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("recipes")
        return try RecipeStore(directory: recipes).load(id: "batman")
    }

    private func residentEvilRecipe() throws -> Recipe {
        let recipes = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("recipes")
        return try RecipeStore(directory: recipes).load(id: "store-2637179839719680")
    }

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("avpplay-local-apk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testRegistrationCopiesToSeparatePersistentRegistryAndRevalidates() throws {
        let dir = try scratch()
        let source = try makeAPK(in: dir)
        let registry = LocalAPKVariantStore(root: dir.appendingPathComponent("local-variants"))
        let sourceHash = try Hashing.sha256(of: source)
        let variant = try registry.register(from: source, recipe: batmanRecipe(),
                                            certificateSubjectObserved: "CN=NotQuestUnderground",
                                            expectedSize: ContentStore.fileSize(source), expectedSHA256: sourceHash)
        let validated = try registry.validated(id: variant.id, for: batmanRecipe())

        XCTAssertEqual(variant.size, ContentStore.fileSize(source))
        XCTAssertEqual(variant.sha256, sourceHash)
        XCTAssertEqual(validated.inspection.package, "com.camouflaj.manta")
        XCTAssertEqual(validated.inspection.versionCode, "350961")
        XCTAssertEqual(validated.inspection.architectures, ["arm64-v8a"])
        XCTAssertEqual(variant.certificateSubjectObserved, "CN=NotQuestUnderground")
        XCTAssertEqual(variant.source, "local")
        XCTAssertEqual(variant.trustStatus, "local-unverified")
        XCTAssertFalse(variant.official)
        XCTAssertFalse(variant.recipeValidated)

        XCTAssertTrue(validated.apk.path.hasPrefix(registry.root.path))
        XCTAssertFalse(validated.apk.path.hasPrefix(dir.appendingPathComponent("store").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "registration leaves its source in place")
    }

    func testDefaultValidationReusesPersistentHashWithoutExplicitCacheArgument() throws {
        let dir = try scratch(), recipe = try batmanRecipe()
        let registry = LocalAPKVariantStore(root: dir.appendingPathComponent("variants"))
        let variant = try registry.register(from: makeAPK(in: dir), recipe: recipe)
        let first = try registry.validated(id: variant.id, for: recipe)
        guard try SHA256FileCache.identity(first.apk).reliable else { throw XCTSkip("Requires APFS") }
        let hits = LockedBox(0)
        _ = try LocalAPKVariantStore(root: registry.root).validated(id: variant.id, for: recipe) { value in
            if value.cached { hits.update { $0 += 1 } }
        }
        XCTAssertEqual(hits.get(), 1)
        let fullHits = LockedBox(0)
        _ = try registry.validated(id: variant.id, for: recipe, forceFull: true) { value in
            if value.cached { fullHits.update { $0 += 1 } }
        }
        XCTAssertEqual(fullHits.get(), 0)
    }

    func testOnlyUnselectedRecipeOptionalAssetsMayBeOmitted() throws {
        let dir = try scratch(), source = try makeAPK(in: dir)
        var recipe = try batmanRecipe()
        let required = RecipeFile(name: "main.obb", role: "obb", id: "r", size: 4,
            sha256: Hashing.sha256(of: Data("good".utf8)), required: true)
        let optional = RecipeFile(name: "extra.obb", role: "obb", id: "o", size: 4,
            sha256: required.sha256, required: false)
        recipe.files = recipe.files.filter { $0.role == "apk" } + [required, optional]
        let requiredURL = dir.appendingPathComponent(required.name), optionalURL = dir.appendingPathComponent(optional.name)
        try Data("good".utf8).write(to: requiredURL)
        let assets = [required, optional].map { file in LocalAPKAsset(name: file.name,
            sourcePath: dir.appendingPathComponent(file.name).path, sourceRootPath: dir.path,
            size: 4, sha256: file.sha256!, recipeSizeMatches: true) }
        let registry = LocalAPKVariantStore(root: dir.appendingPathComponent("variants"))
        var variant = try registry.register(from: source, recipe: recipe, assets: assets)
        XCTAssertThrowsError(try registry.validated(id: variant.id, for: recipe))
        XCTAssertNoThrow(try registry.validated(id: variant.id, for: recipe, selectedAssetNames: []))
        XCTAssertThrowsError(try registry.validated(id: variant.id, for: recipe, selectedAssetNames: [optional.name]))
        try Data("evil".utf8).write(to: optionalURL)
        XCTAssertThrowsError(try registry.validated(id: variant.id, for: recipe, selectedAssetNames: [optional.name]))
        // Changing the local manifest must not override a selected file's authoritative recipe hash.
        variant.assets?[1].sha256 = Hashing.sha256(of: Data("evil".utf8))
        let metadata = registry.root.appendingPathComponent("\(recipe.id)-\(recipe.versionCode)/\(variant.id).json")
        try JSONEncoder().encode(variant).write(to: metadata)
        XCTAssertThrowsError(try registry.validated(id: variant.id, for: recipe, selectedAssetNames: [optional.name]))
        try Data("evil".utf8).write(to: requiredURL)
        XCTAssertThrowsError(try registry.validated(id: variant.id, for: recipe, selectedAssetNames: []))
        try FileManager.default.removeItem(at: requiredURL)
        XCTAssertThrowsError(try registry.validated(id: variant.id, for: recipe, selectedAssetNames: []))
    }

    func testRegistrationChecksSuppliedSizeAndHashBeforeAcceptingSource() throws {
        let dir = try scratch()
        let source = dir.appendingPathComponent("not-an-apk.apk")
        try Data("local bytes".utf8).write(to: source)
        let registry = LocalAPKVariantStore(root: dir.appendingPathComponent("local-variants"))
        XCTAssertThrowsError(try registry.register(from: source, recipe: batmanRecipe(), expectedSize: 1)) {
            XCTAssertTrue($0 is LocalAPKVariantError)
        }
        XCTAssertThrowsError(try registry.register(from: source, recipe: batmanRecipe(), expectedSHA256: String(repeating: "0", count: 64))) {
            XCTAssertTrue($0 is LocalAPKVariantError)
        }
    }

    func testValidationRejectsChangedBytesAndMissingAPK() throws {
        let dir = try scratch()
        let registry = LocalAPKVariantStore(root: dir.appendingPathComponent("local-variants"))
        let recipe = try batmanRecipe()
        let source = try makeAPK(in: dir)
        let variant = try registry.register(from: source, recipe: recipe)
        let installed = try registry.validated(id: variant.id, for: recipe)

        try Data(repeating: 0x41, count: Int(variant.size)).write(to: installed.apk, options: .atomic)
        XCTAssertThrowsError(try registry.validated(id: variant.id, for: recipe)) {
            guard case LocalAPKVariantError.hashMismatch = $0 else { return XCTFail("Expected a hash mismatch, got \($0)") }
        }
        try Data("restore bytes".utf8).write(to: installed.apk, options: .atomic)
        try FileManager.default.removeItem(at: installed.apk)
        XCTAssertThrowsError(try registry.validated(id: variant.id, for: recipe)) {
            guard case LocalAPKVariantError.missing = $0 else { return XCTFail("Expected a missing-file failure, got \($0)") }
        }
    }

    func testValidationRejectsIncompatibleManifestMetadata() throws {
        let recipe = try batmanRecipe()
        let valid = ApkUnpacker.Inspection(package: "com.camouflaj.manta", versionCode: "350961",
                                           versionName: "1.4.1-350961", architectures: ["arm64-v8a"], files: 1)
        XCTAssertNoThrow(try LocalAPKVariantStore.validateMetadata(valid, recipe: recipe))
        XCTAssertThrowsError(try LocalAPKVariantStore.validateMetadata(
            ApkUnpacker.Inspection(package: "com.example.other", versionCode: "350961", versionName: nil,
                                   architectures: ["arm64-v8a"], files: 1), recipe: recipe))
        XCTAssertThrowsError(try LocalAPKVariantStore.validateMetadata(
            ApkUnpacker.Inspection(package: "com.camouflaj.manta", versionCode: "1", versionName: nil,
                                   architectures: ["arm64-v8a"], files: 1), recipe: recipe))
        XCTAssertThrowsError(try LocalAPKVariantStore.validateMetadata(
            ApkUnpacker.Inspection(package: "com.camouflaj.manta", versionCode: "350961", versionName: nil,
                                   architectures: ["armeabi-v7a"], files: 1), recipe: recipe))
    }

    func testLocalRegistrationAllowsDifferentRecipeVersionButKeepsItUnverified() throws {
        let recipe = try batmanRecipe()
        let differentVersion = ApkUnpacker.Inspection(package: recipe.package, versionCode: "350962",
                                                      versionName: "local-build", architectures: ["arm64-v8a"], files: 1)
        XCTAssertNoThrow(try LocalAPKVariantStore.validatePackageAndArchitecture(differentVersion, recipe: recipe))
        XCTAssertThrowsError(try LocalAPKVariantStore.validateMetadata(differentVersion, recipe: recipe))
        XCTAssertEqual(LocalAPKVariantStore.status(inspection: differentVersion, sourceHash: "local", recipe: recipe), "local-unverified")
    }

    func testVersionMismatchCanBeImportedButCannotInstallOrStage() async throws {
        let dir = try scratch()
        var recipe = try batmanRecipe()
        let apkFile = try XCTUnwrap(recipe.files.first(where: { $0.role == "apk" }))
        recipe.files = [apkFile]
        recipe.trees = nil
        let registry = LocalAPKVariantStore(root: dir.appendingPathComponent("local-variants"))
        let localAPK = try makeAPK(in: dir, package: recipe.package, versionCode: "350962", versionName: "local")
        let variant = try registry.register(from: localAPK, recipe: recipe)
        XCTAssertFalse(variant.official)
        XCTAssertFalse(variant.recipeValidated)
        XCTAssertEqual(variant.versionMatchesRecipe, false)

        var request = InstallRequest(toolchain: try Verified850Fixture.source().root.path)
        request.team = "BB7G7A8FSP"
        request.localAPKVariantID = variant.id
        let installer = Installer(recipe: recipe, request: request,
                                  store: ContentStore(root: dir.appendingPathComponent("store")),
                                  localVariants: registry, report: { _ in })
        do {
            try await installer.perform(.build)
            XCTFail("A version mismatch must block installation before contacting a device")
        } catch let error as LocalAPKVariantError {
            guard case .versionMismatch(expected: "350961", actual: "350962") = error else {
                return XCTFail("Unexpected compatibility failure: \(error)")
            }
        }
        do {
            try await installer.perform(.stage)
            XCTFail("A version mismatch must block data transfer before contacting a device")
        } catch let error as LocalAPKVariantError {
            guard case .versionMismatch(expected: "350961", actual: "350962") = error else {
                return XCTFail("Unexpected compatibility failure: \(error)")
            }
        }
    }

    func testValidationChecksRecordedVersionName() throws {
        let dir = try scratch()
        let recipe = try batmanRecipe()
        let registry = LocalAPKVariantStore(root: dir.appendingPathComponent("local-variants"))
        let variant = try registry.register(from: makeAPK(in: dir), recipe: recipe)
        let metadata = registry.root.appendingPathComponent("batman-350961")
            .appendingPathComponent("\(variant.id).json")
        var edited = try JSONDecoder().decode(LocalAPKVariant.self, from: Data(contentsOf: metadata))
        edited.versionName = "different-version"
        try JSONEncoder().encode(edited).write(to: metadata, options: .atomic)
        XCTAssertThrowsError(try registry.validated(id: variant.id, for: recipe)) {
            guard case LocalAPKVariantError.versionMismatch = $0 else {
                return XCTFail("Expected a version-name mismatch, got \($0)")
            }
        }
    }

    func testFolderDiscoveryFindsAPKOutsideOBBAndRegistersAssetsSeparately() throws {
        let dir = try scratch()
        let recipe = try batmanRecipe()
        let apkRecipeFile = try XCTUnwrap(recipe.files.first(where: { $0.role == "apk" }))
        let dataRecipeFile = try XCTUnwrap(recipe.files.first(where: { $0.role != "apk" && $0.required }))
        var fixtureRecipe = recipe
        fixtureRecipe.files = [apkRecipeFile, dataRecipeFile]
        let gameRoot = dir.appendingPathComponent("game", isDirectory: true)
        let obb = gameRoot.appendingPathComponent("Android/obb/\(recipe.package)", isDirectory: true)
        try FileManager.default.createDirectory(at: obb, withIntermediateDirectories: true)
        let externalAPK = try makeAPK(in: gameRoot)
        let asset = obb.appendingPathComponent(dataRecipeFile.name)
        let originalBytes = Data("original external game data".utf8)
        try originalBytes.write(to: asset)
        let originalAssetHash = try Hashing.sha256(of: asset)

        let importer = LocalGameImport()
        let found = try importer.discover(in: gameRoot, recipe: fixtureRecipe)
        XCTAssertEqual(found.apk?.standardizedFileURL.path, externalAPK.standardizedFileURL.path)
        XCTAssertTrue(found.canInstall)
        XCTAssertEqual(found.files[dataRecipeFile.name]?.standardizedFileURL.path, asset.standardizedFileURL.path)

        let registry = LocalAPKVariantStore(root: dir.appendingPathComponent("local-variants"))
        let variant = try importer.register(found, recipe: fixtureRecipe, store: registry)
        let validated = try registry.validated(id: variant.id, for: fixtureRecipe)
        XCTAssertEqual(validated.variant.assets?.map(\.name), [dataRecipeFile.name])
        XCTAssertEqual(validated.variant.assets?.first?.recipeSizeMatches, false)
        XCTAssertEqual(validated.variant.assets?.first?.recipeHashMatches, false)
        XCTAssertEqual(try Hashing.sha256(of: asset), originalAssetHash)
        XCTAssertEqual(try Data(contentsOf: asset), originalBytes, "the external source must remain unchanged")
        XCTAssertFalse(variant.official)
        XCTAssertFalse(variant.recipeValidated)

        var request = InstallRequest(toolchain: "/unused")
        request.localAPKVariantID = variant.id
        let installer = Installer(recipe: fixtureRecipe, request: request,
                                  store: ContentStore(root: dir.appendingPathComponent("empty-store")),
                                  localVariants: registry, report: { _ in })
        XCTAssertThrowsError(try installer.localFiles(),
            "Analysis may retain mismatched source data, but staging must reject mandatory recipe size/hash mismatches")

        try Data(repeating: 0x45, count: originalBytes.count).write(to: asset, options: .atomic)
        XCTAssertNoThrow(try registry.validated(id: variant.id, for: fixtureRecipe,
                                                 verifyAssetHashes: false, verifyAPKHash: false),
                         "build-only may reuse hashes recorded by import while still validating file existence and size")
        XCTAssertThrowsError(try registry.validated(id: variant.id, for: fixtureRecipe)) {
            guard case LocalAPKVariantError.hashMismatch = $0 else {
                return XCTFail("Expected external data hash mismatch, got \($0)")
            }
        }
        try originalBytes.write(to: asset, options: .atomic)
    }

    func testFolderDiscoveryUsesExplicitAdditionalSourcesWithoutCredentials() throws {
        let dir = try scratch()
        let recipe = try batmanRecipe()
        let apkRecipeFile = try XCTUnwrap(recipe.files.first(where: { $0.role == "apk" }))
        let dataRecipeFile = try XCTUnwrap(recipe.files.first(where: { $0.role != "apk" && $0.required }))
        var fixtureRecipe = recipe
        fixtureRecipe.files = [apkRecipeFile, dataRecipeFile]
        fixtureRecipe.trees = nil
        let gameRoot = dir.appendingPathComponent("game-root", isDirectory: true)
        try FileManager.default.createDirectory(at: gameRoot, withIntermediateDirectories: true)
        _ = try makeAPK(in: gameRoot)
        let extraRoot = dir.appendingPathComponent("separately-selected-data", isDirectory: true)
        try FileManager.default.createDirectory(at: extraRoot, withIntermediateDirectories: true)
        let asset = extraRoot.appendingPathComponent(dataRecipeFile.name)
        try Data("local data without account credentials".utf8).write(to: asset)

        let discovered = try LocalGameImport().discover(in: gameRoot, recipe: fixtureRecipe, additionalSources: [extraRoot])
        XCTAssertEqual(discovered.files[dataRecipeFile.name]?.standardizedFileURL, asset.standardizedFileURL)
        XCTAssertTrue(discovered.missingRequired.isEmpty)
        let registry = LocalAPKVariantStore(root: dir.appendingPathComponent("local-variants"))
        let variant = try LocalGameImport().register(discovered, recipe: fixtureRecipe, store: registry)
        let checked = try registry.validated(id: variant.id, for: fixtureRecipe, verifyAssetHashes: true)
        XCTAssertEqual(checked.variant.assets?.first?.sourceRootPath, extraRoot.standardizedFileURL.path)
        XCTAssertFalse(checked.variant.official)
        XCTAssertFalse(checked.variant.recipeValidated)
    }

    func testLocalAssetSymlinkCannotEscapeItsRecordedSourceRoot() throws {
        let dir = try scratch()
        let recipe = try batmanRecipe()
        let apkRecipeFile = try XCTUnwrap(recipe.files.first(where: { $0.role == "apk" }))
        let dataRecipeFile = try XCTUnwrap(recipe.files.first(where: { $0.role != "apk" && $0.required }))
        var fixtureRecipe = recipe
        fixtureRecipe.files = [apkRecipeFile, dataRecipeFile]
        fixtureRecipe.trees = nil
        let gameRoot = dir.appendingPathComponent("game-root", isDirectory: true)
        try FileManager.default.createDirectory(at: gameRoot, withIntermediateDirectories: true)
        _ = try makeAPK(in: gameRoot)
        let outside = dir.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let externalAsset = outside.appendingPathComponent(dataRecipeFile.name)
        try Data("outside selected source".utf8).write(to: externalAsset)
        let link = gameRoot.appendingPathComponent(dataRecipeFile.name)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: externalAsset)

        let discovered = try LocalGameImport().discover(in: gameRoot, recipe: fixtureRecipe)
        XCTAssertNil(discovered.files[dataRecipeFile.name], "the importer must not follow a file symlink out of the selected folder")
        XCTAssertEqual(discovered.missingRequired, [dataRecipeFile.name])
        XCTAssertFalse(discovered.canInstall)
    }

    func testDiscoveryReportsMissingAPKInsteadOfTreatingOBBAsAPK() throws {
        let dir = try scratch()
        let recipe = try batmanRecipe()
        let apkRecipeFile = try XCTUnwrap(recipe.files.first(where: { $0.role == "apk" }))
        let dataRecipeFile = try XCTUnwrap(recipe.files.first(where: { $0.role != "apk" && $0.required }))
        var fixtureRecipe = recipe
        fixtureRecipe.files = [apkRecipeFile, dataRecipeFile]
        let obb = dir.appendingPathComponent("Android/obb/\(recipe.package)", isDirectory: true)
        try FileManager.default.createDirectory(at: obb, withIntermediateDirectories: true)
        try Data("not an apk".utf8).write(to: obb.appendingPathComponent(dataRecipeFile.name))

        let found = try LocalGameImport().discover(in: dir, recipe: fixtureRecipe)
        XCTAssertNil(found.apk)
        XCTAssertFalse(found.canInstall)
        XCTAssertEqual(found.missingRequired, [apkRecipeFile.name])
    }

    func testDiscoverBatmanFolderFromConfiguredExternalDrive() throws {
        guard let path = ProcessInfo.processInfo.environment["AVPPLAY_BATMAN_GAME_FOLDER"] else {
            throw XCTSkip("Set AVPPLAY_BATMAN_GAME_FOLDER to run the read-only external-drive discovery check")
        }
        let recipe = try batmanRecipe()
        let found = try LocalGameImport().discover(in: URL(fileURLWithPath: path), recipe: recipe)
        XCTAssertEqual(found.apk?.lastPathComponent, "base.apk")
        XCTAssertEqual(found.apkInspection?.package, recipe.package)
        XCTAssertTrue(found.canInstall, "Missing required files: \(found.missingRequired.joined(separator: ", "))")
        print("External folder APK: \(found.apk?.path ?? "missing") versionCode=\(found.apkInspection?.versionCode ?? "unknown"); required files found=\(recipe.files.filter(\.required).count - found.missingRequired.count)/\(recipe.files.filter(\.required).count)")
    }

    func testResidentEvilRecipeUsesGenericLocalPreparationTarget() throws {
        let dir = try scratch()
        var recipe = try residentEvilRecipe()
        // This unit checks APK preparation only; dependency validation has separate tests.
        recipe.files = recipe.files.filter { $0.role == "apk" }
        let registry = LocalAPKVariantStore(root: dir.appendingPathComponent("local-variants"))
        let source = try makeAPK(in: dir, package: recipe.package, versionCode: String(recipe.versionCode),
                                 versionName: recipe.versionName)
        let variant = try registry.register(from: source, recipe: recipe)
        let toolchainRoot = dir.appendingPathComponent("toolchain", isDirectory: true)
        let verified = try Verified850Fixture.workspace(at: toolchainRoot)
        let scriptHash = try Hashing.sha256(of: verified.root.appendingPathComponent("visionos/run.sh"))
        let store = ContentStore(root: dir.appendingPathComponent("store", isDirectory: true))
        let prepared = try LocalAPKPreparer().prepare(recipe: recipe, variantID: variant.id, store: store,
                                                      toolchain: Toolchain(root: toolchainRoot), localVariants: registry)
        XCTAssertEqual(try Hashing.sha256(of: verified.root.appendingPathComponent("visionos/run.sh")), scriptHash)
        XCTAssertEqual(prepared.lastPathComponent, "re4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.appendingPathComponent(".qi-prepared").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: toolchainRoot.appendingPathComponent("re4.apk").path))
    }

    func testResidentEvilTargetResolutionAndIsolatedDataPanelMetadata() throws {
        let recipe = try residentEvilRecipe()
        let resolved = KleptonRecipeCompatibility.resolve(recipe)
        XCTAssertEqual(resolved.toolchain.target, "re4")
        XCTAssertEqual(resolved.files.first(where: { $0.role == "apk" })?.localName, "re4.apk")
        XCTAssertEqual(recipe.toolchain.target, "x2637179839719680", "catalog recipe stays unchanged")
        XCTAssertEqual(recipe.files.first(where: { $0.role == "apk" })?.localName, "x2637179839719680.apk")

        let dir = try scratch()
        let visionOS = dir.appendingPathComponent("visionos", isDirectory: true)
        try FileManager.default.createDirectory(at: visionOS, withIntermediateDirectories: true)
        let targets = visionOS.appendingPathComponent("targets.py")
        let otherTargetEntry = "        \"obb_file\": \"leave-this-target-alone.obb\","
        try "TARGETS = {\n    \"re4\": {\n        \"obb\":     \"Android/obb/com.Armature.VR4\",\n        \"obb_file\": \"stale.obb\",\n        \"obb_file\": \"duplicate.obb\",\n    },\n    \"other\": {\n\(otherTargetEntry)\n    }\n}\n"
            .write(to: targets, atomically: true, encoding: .utf8)
        try KleptonRecipeCompatibility.addResidentEvilTargetMetadata(to: dir)
        try KleptonRecipeCompatibility.addResidentEvilTargetMetadata(to: dir)
        let updated = try String(contentsOf: targets, encoding: .utf8)
        let re4Block = try XCTUnwrap(updated.components(separatedBy: "    \"other\": {").first)
        XCTAssertEqual(re4Block.components(separatedBy: "\"obb_file\":").count - 1, 1)
        XCTAssertTrue(re4Block.contains("\"obb_file\": \"main.203.com.Armature.VR4.obb\""))
        XCTAssertTrue(re4Block.contains("\"obb\":     \"Android/obb/com.Armature.VR4\""))
        XCTAssertTrue(updated.contains(otherTargetEntry), "metadata on other targets must remain unchanged")
    }

    func testResidentEvilToolchainMetadataIsAppliedOnlyToWorkingCopy() throws {
        let dir = try scratch()
        let source = dir.appendingPathComponent("source", isDirectory: true)
        let visionOS = source.appendingPathComponent("visionos", isDirectory: true)
        try FileManager.default.createDirectory(at: visionOS, withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: visionOS.appendingPathComponent("run.sh"), atomically: true, encoding: .utf8)
        let targetsText = "TARGETS = {\n    \"re4\": {\n        \"obb\":     \"Android/obb/com.Armature.VR4\",\n    },\n    \"other\": {},\n}\n"
        let targets = visionOS.appendingPathComponent("targets.py")
        try targetsText.write(to: targets, atomically: true, encoding: .utf8)
        let manifest = ToolchainManifest(format: ToolchainManifest.currentFormat, version: 507, commit: "abc1234",
                                         ancestors: ["abc1234"], created: Date())
        try ToolchainPackager.encoder.encode(manifest).write(to: source.appendingPathComponent("toolchain.json"))
        let original = try Toolchain(root: source)
        let overlay = try KleptonRecipeCompatibility.residentEvilToolchainCopy(
            from: original, under: dir.appendingPathComponent("overlays", isDirectory: true))
        XCTAssertNotEqual(overlay.root, source)
        XCTAssertTrue(overlay.isModified)
        XCTAssertFalse(try String(contentsOf: targets, encoding: .utf8).contains("obb_file"))
        XCTAssertTrue(try String(contentsOf: overlay.root.appendingPathComponent("visionos/targets.py"), encoding: .utf8)
            .contains("main.203.com.Armature.VR4.obb"))
    }

    func testResidentEvilLocalRegistrationKeepsDifferentAPKHashAndValidatesBothOBBs() throws {
        let dir = try scratch()
        let base = try residentEvilRecipe()
        var recipe = base
        let game = dir.appendingPathComponent("game", isDirectory: true)
        let obbDir = game.appendingPathComponent("Android/obb/com.Armature.VR4", isDirectory: true)
        try FileManager.default.createDirectory(at: obbDir, withIntermediateDirectories: true)
        let apk = try makeAPK(in: game, package: recipe.package, versionCode: String(recipe.versionCode), versionName: recipe.versionName)
        let localAPKHash = try Hashing.sha256(of: apk)
        let apkIndex = try XCTUnwrap(recipe.files.firstIndex(where: { $0.role == "apk" }))
        recipe.files[apkIndex].sha256 = String(repeating: "0", count: 64)
        XCTAssertNotEqual(localAPKHash, recipe.files[apkIndex].sha256)
        for index in recipe.files.indices where recipe.files[index].role != "apk" {
            let file = obbDir.appendingPathComponent(recipe.files[index].name)
            try Data((recipe.files[index].name + " fixture bytes").utf8).write(to: file)
            recipe.files[index].size = ContentStore.fileSize(file)
            recipe.files[index].sha256 = try Hashing.sha256(of: file)
        }

        let found = try LocalGameImport().discover(in: game, recipe: recipe)
        XCTAssertTrue(found.canInstall)
        let registry = LocalAPKVariantStore(root: dir.appendingPathComponent("local-variants"))
        let variant = try LocalGameImport().register(found, recipe: recipe, store: registry)
        let validated = try registry.validated(id: variant.id, for: recipe, verifyAssetHashes: true)
        XCTAssertEqual(validated.variant.sha256, localAPKHash)
        XCTAssertEqual(validated.variant.officialAPKHashMatchesRecipe, false)
        XCTAssertFalse(validated.variant.official)
        XCTAssertFalse(validated.variant.recipeValidated)
        XCTAssertEqual(Set(validated.variant.assets?.map(\.name) ?? []), Set([
            "main.203.com.Armature.VR4.obb", "patch.203.com.Armature.VR4.obb"
        ]))
        XCTAssertTrue(validated.variant.assets?.allSatisfy { $0.recipeHashMatches == true } == true)

        let main = try XCTUnwrap(validated.variant.assets?.first { $0.name.hasPrefix("main.") })
        let mainURL = URL(fileURLWithPath: main.sourcePath)
        let originalMain = try Data(contentsOf: mainURL)
        try FileManager.default.removeItem(at: mainURL)
        XCTAssertThrowsError(try registry.validated(id: variant.id, for: recipe, verifyAssetHashes: true)) {
            guard case LocalAPKVariantError.missing = $0 else {
                return XCTFail("A disconnected or missing external drive file must stop validation: \($0)")
            }
        }
        try originalMain.write(to: mainURL)

        let patch = obbDir.appendingPathComponent("patch.203.com.Armature.VR4.obb")
        let patchSize = try XCTUnwrap(ContentStore.fileSize(patch))
        try Data(repeating: 0x58, count: Int(patchSize)).write(to: patch, options: .atomic)
        XCTAssertThrowsError(try registry.validated(id: variant.id, for: recipe, verifyAssetHashes: true)) {
            guard case LocalAPKVariantError.hashMismatch = $0 else { return XCTFail("Expected OBB integrity failure, got \($0)") }
        }
    }

    func testResidentEvilStagePlanUsesBothLocalOBBsAtAndroidPath() throws {
        var recipe = try residentEvilRecipe()
        let dir = try scratch()
        let gameRoot = dir.appendingPathComponent("external-game", isDirectory: true)
        let obbRoot = gameRoot.appendingPathComponent("Android/obb/com.Armature.VR4", isDirectory: true)
        try FileManager.default.createDirectory(at: obbRoot, withIntermediateDirectories: true)
        for file in recipe.files where file.role != "apk" {
            let source = obbRoot.appendingPathComponent(file.name)
            try Data(file.name.utf8).write(to: source)
        }
        for index in recipe.files.indices where recipe.files[index].role != "apk" {
            let bytes = Data(recipe.files[index].name.utf8)
            recipe.files[index].size = Int64(bytes.count)
            recipe.files[index].sha256 = Hashing.sha256(of: bytes)
        }
        _ = try makeAPK(in: gameRoot, package: recipe.package, versionCode: String(recipe.versionCode),
                        versionName: recipe.versionName)
        let discovery = try LocalGameImport().discover(in: gameRoot, recipe: recipe)
        let registry = LocalAPKVariantStore(root: dir.appendingPathComponent("local-variants"))
        let variant = try LocalGameImport().register(discovery, recipe: recipe, store: registry)
        let validated = try registry.validated(id: variant.id, for: recipe, verifyAssetHashes: true)
        var request = InstallRequest(toolchain: "/unused")
        request.localAPKVariantID = variant.id
        let installer = Installer(recipe: recipe, request: request,
                                  store: ContentStore(root: dir.appendingPathComponent("empty-store")),
                                  localVariants: registry, report: { _ in })
        let files = try installer.localFiles()
        let plan = StagePlan.plan(local: files, remote: [:])
        XCTAssertFalse(validated.variant.official)
        XCTAssertFalse(validated.variant.recipeValidated)
        XCTAssertEqual(validated.variant.trustStatus, "local-unverified")
        XCTAssertEqual(Set(plan.map(\.destination)), Set([
            "Documents/re4.apk",
            "Documents/android-files/Android/obb/com.Armature.VR4/main.203.com.Armature.VR4.obb",
            "Documents/android-files/Android/obb/com.Armature.VR4/patch.203.com.Armature.VR4.obb"
        ]))
        XCTAssertEqual(Set(plan.map { $0.source.standardizedFileURL.path }), Set(files.map { $0.url.standardizedFileURL.path }))
        XCTAssertEqual(Set(plan.filter { !$0.destination.hasSuffix(".apk") }.map { $0.source.deletingLastPathComponent().standardizedFileURL.path }), [obbRoot.standardizedFileURL.path])
    }

    func testDiscoverResidentEvilFolderFromConfiguredExternalDrive() throws {
        guard let path = ProcessInfo.processInfo.environment["AVPPLAY_RE4_GAME_FOLDER"] else {
            throw XCTSkip("Set AVPPLAY_RE4_GAME_FOLDER to run the read-only Resident Evil 4 external-drive check")
        }
        let recipe = try residentEvilRecipe()
        let found = try LocalGameImport().discover(in: URL(fileURLWithPath: path), recipe: recipe)
        XCTAssertEqual(found.apk?.lastPathComponent, "base.apk")
        XCTAssertEqual(found.apkInspection?.package, "com.Armature.VR4")
        XCTAssertEqual(found.apkInspection?.versionCode, "203")
        XCTAssertEqual(found.apkInspection?.versionName, "2.3")
        XCTAssertEqual(found.apkInspection?.architectures, ["arm64-v8a"])
        XCTAssertTrue(found.canInstall, "Missing required files: \(found.missingRequired.joined(separator: ", "))")
        XCTAssertEqual(found.files.count, 2)
        for file in recipe.files where file.role != "apk" {
            let foundURL = try XCTUnwrap(found.files[file.name])
            XCTAssertEqual(ContentStore.fileSize(foundURL), file.size)
        }
        print("Resident Evil 4 local discovery: package=\(found.apkInspection?.package ?? "?"), "
              + "version=\(found.apkInspection?.versionName ?? "?") (\(found.apkInspection?.versionCode ?? "?")), "
              + "architectures=\(found.apkInspection?.architectures.sorted().joined(separator: ",") ?? "?"), "
              + "supporting files=\(found.files.count), APK size=\(ContentStore.fileSize(try XCTUnwrap(found.apk)) ?? 0) "
              + "(recipe expects \(recipe.files.first(where: { $0.role == "apk" })?.size ?? 0)); source files remain unmodified")
    }

    func testLocalJobChecksMetaAndLocalFetchReturnsWithoutNetworkFallback() async throws {
        XCTAssertEqual(InstallStep.localAPKValidation, [.fetch])
        XCTAssertEqual(InstallStep.localAPKInstall, [.fetch, .build, .stage])
        XCTAssertEqual(InstallStep.localAPKStage, [.fetch, .stage])
        XCTAssertFalse(InstallStep.localAPKInstall.contains(.unlock))
        XCTAssertFalse(InstallStep.localAPKStage.contains(.unlock))
        XCTAssertFalse(InstallStep.localAPKInstall.contains(.account))
        XCTAssertFalse(InstallStep.localAPKStage.contains(.account))
        XCTAssertFalse(InstallStep.localAPKStage.contains(.build))
        XCTAssertEqual(InstallStep.localAPKBuildOnly, [.buildOnly])
        XCTAssertEqual(InstallStep.fullInstall, [.account, .fetch, .build, .stage, .unlock])
        let defaultRequest = InstallRequest(toolchain: "/toolchain")
        XCTAssertNil(defaultRequest.localAPKVariantID, "recipe/Meta remains the default")

        let dir = try scratch()
        let base = try batmanRecipe()
        var recipe = base
        let apkFile = try XCTUnwrap(recipe.files.first(where: { $0.role == "apk" }))
        recipe.files = [apkFile]
        recipe.trees = nil
        let registry = LocalAPKVariantStore(root: dir.appendingPathComponent("local-variants"))
        let variant = try registry.register(from: makeAPK(in: dir), recipe: recipe)
        var request = defaultRequest
        request.localAPKVariantID = variant.id
        request.account = "local-fetch-without-meta-\(UUID().uuidString)"
        let messages = LockedBox<[String]>([])
        let installer = Installer(recipe: recipe, request: request,
                                  store: ContentStore(root: dir.appendingPathComponent("empty-store")),
                                  localVariants: registry, report: { message in messages.set(messages.get() + [message]) })
        try await installer.perform(.account)
        try await installer.perform(.fetch)
        XCTAssertTrue(messages.get().contains { $0.contains("network fetch skipped") })
    }

    func testOfficialFetchStillRequiresMetaTokenWhenFilesNeedDownloading() async throws {
        var recipe = try batmanRecipe()
        let apk = try XCTUnwrap(recipe.files.first(where: { $0.role == "apk" }))
        recipe.files = [apk]
        recipe.trees = nil
        var request = InstallRequest(toolchain: "/unused")
        request.account = "no-meta-token-\(UUID().uuidString)"
        let installer = Installer(recipe: recipe, request: request,
                                  store: ContentStore(root: FileManager.default.temporaryDirectory
                                    .appendingPathComponent("avpplay-empty-\(UUID().uuidString)")),
                                  report: { _ in })
        do {
            try await installer.perform(.fetch)
            XCTFail("The official Meta download path must require its account token")
        } catch {
            XCTAssertFalse(error is LocalAPKVariantError)
        }
    }

    func testExplicitMissingLocalVariantFailsWithoutOfficialFetchFallback() async throws {
        let dir = try scratch()
        var recipe = try batmanRecipe()
        let apkFile = try XCTUnwrap(recipe.files.first(where: { $0.role == "apk" }))
        recipe.files = [apkFile]
        recipe.trees = nil
        var request = InstallRequest(toolchain: "/unused")
        request.localAPKVariantID = "explicit-but-missing-local-variant"
        let reports = LockedBox<[String]>([])
        let installer = Installer(recipe: recipe, request: request,
                                  store: ContentStore(root: dir.appendingPathComponent("official-files-must-not-be-read")),
                                  localVariants: LocalAPKVariantStore(root: dir.appendingPathComponent("local-variants")),
                                  report: { reports.set(reports.get() + [$0]) })

        do {
            try await installer.perform(.fetch)
            XCTFail("An invalid explicit local variant must fail instead of using the official recipe")
        } catch let error as LocalAPKVariantError {
            guard case .missing = error else { return XCTFail("Unexpected error: \(error)") }
        } catch {
            let missing = error as NSError
            XCTAssertEqual(missing.domain, NSCocoaErrorDomain)
            XCTAssertEqual(missing.code, NSFileReadNoSuchFileError)
        }
        XCTAssertFalse(reports.get().contains { $0.localizedCaseInsensitiveContains("download") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("official-files-must-not-be-read").path))
    }

    func testLocalMetaOwnershipMustBeAffirmativeAndReachable() async throws {
        do {
            try await MetaOwnershipCheck.requireConfirmation(title: "RE4") { false }
            XCTFail("A negative Meta ownership answer must stop the job")
        } catch let error as InstallError {
            XCTAssertEqual(error, .notOwned("RE4"))
        }
        do {
            try await MetaOwnershipCheck.requireConfirmation(title: "RE4") { throw CocoaError(.userCancelled) }
            XCTFail("An unavailable Meta verification must stop the local job")
        } catch let error as InstallError {
            guard case .ownershipUnverified = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testLocalSigningRecordRetainsVariantAndOverlayForRenewal() throws {
        let record = SigningRecord(team: "BB7G7A8FSP", free: true, installed: Date(timeIntervalSince1970: 1),
                                   expires: nil, localAPKVariantID: "re4-local-variant", toolchainPath: "/isolated/re4-toolchain")
        let roundTrip = try JSONDecoder().decode(SigningRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(roundTrip.localAPKVariantID, "re4-local-variant")
        XCTAssertEqual(roundTrip.toolchainPath, "/isolated/re4-toolchain")
    }

    func testIsolatedPreparerCreatesIntermediatesWithoutRunningBuildOrDeviceScript() throws {
        let dir = try scratch()
        var recipe = try batmanRecipe()
        // This unit checks APK preparation only; dependency validation has separate tests.
        recipe.files = recipe.files.filter { $0.role == "apk" }
        let registry = LocalAPKVariantStore(root: dir.appendingPathComponent("local-variants"))
        let variant = try registry.register(from: makeAPK(in: dir), recipe: recipe)
        let toolchainRoot = dir.appendingPathComponent("toolchain", isDirectory: true)
        let verified = try Verified850Fixture.workspace(at: toolchainRoot)
        let scriptHash = try Hashing.sha256(of: verified.root.appendingPathComponent("visionos/run.sh"))
        let store = ContentStore(root: dir.appendingPathComponent("store", isDirectory: true))
        let toolchain = try Toolchain(root: toolchainRoot)

        let prepared = try LocalAPKPreparer().prepare(recipe: recipe, variantID: variant.id,
                                                      store: store, toolchain: toolchain,
                                                      localVariants: registry)

        XCTAssertEqual(prepared.path, toolchainRoot.appendingPathComponent("batman", isDirectory: true).path)
        XCTAssertEqual(try Hashing.sha256(of: toolchainRoot.appendingPathComponent("batman.apk")), variant.sha256)
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.appendingPathComponent(".qi-prepared").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.appendingPathComponent("AndroidManifest.xml").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.appendingPathComponent("lib/arm64-v8a/libmain.so").path))
        XCTAssertEqual(try Hashing.sha256(of: verified.root.appendingPathComponent("visionos/run.sh")), scriptHash)
        XCTAssertFalse(FileManager.default.fileExists(atPath: toolchainRoot.appendingPathComponent("visionos/build").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory(for: recipe).appendingPathComponent(".last-build.log").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("jobs").path))
    }

    /// Opt-in integration check used once to register the specifically authorized APK through production code.
    func testRegisterAuthorizedQuestAPKInPersistentAVPPlayDirectoryWhenRequested() throws {
        guard let sourcePath = ProcessInfo.processInfo.environment["AVPPLAY_REGISTER_BATMAN_APK"] else {
            throw XCTSkip("Set AVPPLAY_REGISTER_BATMAN_APK only for the explicit persistent registration operation")
        }
        let root = ProcessInfo.processInfo.environment["AVPPLAY_LOCAL_VARIANT_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? DataLocation.base.appendingPathComponent("local-variants", isDirectory: true)
        let variant = try LocalAPKVariantStore(root: root).register(
            from: URL(fileURLWithPath: sourcePath), recipe: batmanRecipe(),
            certificateSubjectObserved: "CN=NotQuestUnderground", expectedSize: 85_966_835,
            expectedSHA256: "ed8d7ab7b95a40075d6b1315e2ccb785055c0baed8362bffe549d77b9f664cd7")
        let validated = try LocalAPKVariantStore(root: root).validated(id: variant.id, for: batmanRecipe())
        XCTAssertEqual(validated.variant.sha256, "ed8d7ab7b95a40075d6b1315e2ccb785055c0baed8362bffe549d77b9f664cd7")
        XCTAssertEqual(validated.variant.size, 85_966_835)
        XCTAssertFalse(validated.variant.official)
        XCTAssertFalse(validated.variant.recipeValidated)
    }

    func testAutomaticMatchingUsesIdentityForEveryAPKRecipe() throws {
        let location = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("recipes")
        let all = try RecipeStore(directory: location).loadAll()
        XCTAssertEqual(all.count, 48)
        XCTAssertTrue(all.contains { $0.package == "com.magnopus.ElixirStore" && $0.versionCode == 2400 })
        let dir = try scratch()
        for recipe in all where recipe.files.contains(where: { $0.role == "apk" }) && !recipe.package.isEmpty {
            let apk = try makeAPK(in: dir, package: recipe.package, versionCode: String(recipe.versionCode), versionName: recipe.versionName)
            let matches = try LocalGameImport.matchingRecipes(apk: apk, recipes: all)
            XCTAssertTrue(matches.contains(where: { $0.id == recipe.id }), recipe.id)
            XCTAssertTrue(matches.allSatisfy { $0.package == recipe.package && $0.versionCode == recipe.versionCode })
        }
    }

    func testLearningRequiresAuthorizationAndMatchingCompletedReceipt() throws {
        let dir = try scratch()
        var recipe = try batmanRecipe()
        recipe.files = recipe.files.filter { $0.role == "apk" }
        let registry = LocalAPKVariantStore(root: dir.appendingPathComponent("variants"))
        let variant = try registry.register(from: makeAPK(in: dir), recipe: recipe)
        let store = LocalAPKLearningStore(variants: registry)
        XCTAssertEqual(try store.status(variant, recipe: recipe), .unverified)
        XCTAssertThrowsError(try store.confirmLearning(variant, recipe: recipe, receiptID: "missing"))
        try store.authorize(variant, recipe: recipe, allowed: true)
        XCTAssertThrowsError(try store.confirmLearning(variant, recipe: recipe, receiptID: "missing"))
        let receipt = LocalAPKInstallation(id: "completed", variantID: variant.id, sha256: variant.sha256,
            size: variant.size, package: variant.package, versionCode: variant.versionCode,
            bundleID: "test.local.game", deviceID: "test-device", team: "TESTTEAM01", toolchain: "750-test", date: Date())
        var wrong = receipt; wrong.sha256 = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try store.recordInstallation(wrong, variant: variant, recipe: recipe))
        try store.recordInstallation(receipt, variant: variant, recipe: recipe)
        XCTAssertEqual(try store.status(variant, recipe: recipe), .installed)
        XCTAssertNil(try store.load(recipe).current, "Successful installation must not silently learn")
        try store.confirmLearning(variant, recipe: recipe, receiptID: receipt.id)
        XCTAssertEqual(try store.status(variant, recipe: recipe), .recognized)
        XCTAssertFalse(variant.official)
        XCTAssertFalse(variant.recipeValidated)
        let reopened = LocalAPKLearningStore(variants: registry)
        XCTAssertEqual(try reopened.load(recipe).current?.hashes[variant.sha256], variant.size)
        XCTAssertEqual(try reopened.load(recipe).installations.count, 1)
        try reopened.authorize(variant, recipe: recipe, allowed: false)
        XCTAssertThrowsError(try reopened.requireAuthorized(variant, recipe: recipe))
    }

    func testSeveralHashesAndRestoreRetainHistoryAndOfficialRecipe() throws {
        let dir = try scratch()
        var recipe = try batmanRecipe()
        recipe.files = recipe.files.filter { $0.role == "apk" }
        let before = try JSONEncoder().encode(recipe)
        let registry = LocalAPKVariantStore(root: dir.appendingPathComponent("variants"))
        let store = LocalAPKLearningStore(variants: registry)
        let first = try registry.register(from: makeAPK(in: dir), recipe: recipe)
        let second = try registry.register(from: makeAPK(in: dir, versionName: "second local build"), recipe: recipe)
        XCTAssertNotEqual(first.sha256, second.sha256)
        for variant in [first, second] {
            try store.authorize(variant, recipe: recipe, allowed: true)
            let receipt = LocalAPKInstallation(id: variant.id, variantID: variant.id, sha256: variant.sha256,
                size: variant.size, package: variant.package, versionCode: variant.versionCode,
                bundleID: "test.local.game", deviceID: "test-device", team: "TESTTEAM01", toolchain: "750-test", date: Date())
            try store.recordInstallation(receipt, variant: variant, recipe: recipe)
            try store.confirmLearning(variant, recipe: recipe, receiptID: receipt.id)
        }
        let record = try store.load(recipe)
        XCTAssertEqual(record.current?.hashes.count, 2)
        try store.restore(record.revisions.first!.id, recipe: recipe)
        XCTAssertEqual(try store.load(recipe).current?.hashes.count, 2, "Restoring must retain learned hashes")
        XCTAssertEqual(try store.load(recipe).installations.count, 2)
        XCTAssertEqual(try store.load(recipe).revisions.count, 3)
        try store.restore(nil, recipe: recipe)
        XCTAssertEqual(try store.load(recipe).current?.hashes.count, 2, "Reset must retain learned hashes")
        XCTAssertEqual(try store.load(recipe).revisions.count, 4)
        XCTAssertEqual(try JSONDecoder().decode(Recipe.self, from: before).files, recipe.files)
        XCTAssertEqual(registry.variants(for: recipe).count, 2)
    }

    func testChangedRecipeAndMalformedLearningRecordFailClosed() throws {
        let dir = try scratch(), recipe = try batmanRecipe()
        let registry = LocalAPKVariantStore(root: dir.appendingPathComponent("variants"))
        let variant = try registry.register(from: makeAPK(in: dir), recipe: recipe)
        let store = LocalAPKLearningStore(variants: registry)
        var changed = recipe; changed.versionCode += 1
        XCTAssertThrowsError(try store.authorize(variant, recipe: changed, allowed: true))
        try store.authorize(variant, recipe: recipe, allowed: true)
        let file = store.root.appendingPathComponent("\(recipe.id)-\(recipe.versionCode).json")
        try Data("invalid record".utf8).write(to: file)
        XCTAssertThrowsError(try store.load(recipe))
        XCTAssertThrowsError(try store.authorize(variant, recipe: recipe, allowed: true))
    }

    func testUnsignedAndInvalidAPKSignaturesAreNotVerified() throws {
        let dir = try scratch()
        let source = try makeAPK(in: dir)
        XCTAssertFalse(try AndroidAPKSignature.inspect(source).verified)
        let bad = dir.appendingPathComponent("bad.apk")
        try Data("not a ZIP".utf8).write(to: bad)
        XCTAssertEqual(try AndroidAPKSignature.inspect(bad).state, "invalid")
    }

    func testDependencyMismatchRemainsBlockedForLocalVariants() throws {
        let dir = try scratch(), recipe = try residentEvilRecipe()
        let registry = LocalAPKVariantStore(root: dir.appendingPathComponent("variants"))
        let apk = try makeAPK(in: dir, package: recipe.package, versionCode: "203", versionName: "2.3")
        let variant = try registry.register(from: apk, recipe: recipe)
        XCTAssertThrowsError(try LocalAPKVariantStore.requireCompatibleDependencies(variant, recipe: recipe))
        var incompatible = variant; incompatible.versionCode = "204"
        XCTAssertEqual(try LocalAPKLearningStore(variants: registry).status(incompatible, recipe: recipe), .incompatible)
    }

    func testAndroidV1SignatureValidatesPayloadAndRejectsTampering() throws {
        let dir = try scratch()
        let apk = try makeAPK(in: dir)
        let script = #"""
import pathlib,sys,zipfile,hashlib,base64,subprocess
root=pathlib.Path(sys.argv[1]);apk=root/'synthetic.apk'
with zipfile.ZipFile(apk) as z: payload={n:z.read(n) for n in z.namelist() if not n.endswith('/')}
def digest(b):return base64.b64encode(hashlib.sha256(b).digest()).decode()
mf='Manifest-Version: 1.0\r\n\r\n'+''.join('Name: '+n+'\r\nSHA-256-Digest: '+digest(b)+'\r\n\r\n' for n,b in payload.items())
sf=('Signature-Version: 1.0\r\nSHA-256-Digest-Manifest: '+digest(mf.encode())+'\r\n\r\n').encode()
(root/'signature.sf').write_bytes(sf)
subprocess.run(['/usr/bin/openssl','req','-x509','-newkey','rsa:2048','-nodes','-keyout',str(root/'test.key'),'-out',str(root/'test.crt'),'-subj','/CN=AVP Local Test Fixture','-days','1'],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
subprocess.run(['/usr/bin/openssl','smime','-sign','-binary','-in',str(root/'signature.sf'),'-signer',str(root/'test.crt'),'-inkey',str(root/'test.key'),'-outform','DER','-out',str(root/'signature.der')],check=True)
with zipfile.ZipFile(apk,'a') as z:
 z.writestr('META-INF/MANIFEST.MF',mf);z.writestr('META-INF/TEST.SF',sf);z.writestr('META-INF/TEST.RSA',(root/'signature.der').read_bytes())
"""#
        _ = try ApkUnpacker.run(["/usr/bin/python3", "-c", script, dir.path])
        let signature = try AndroidAPKSignature.inspect(apk)
        XCTAssertTrue(signature.verified, signature.detail)
        XCTAssertTrue(signature.subject?.contains("AVP Local Test Fixture") == true)
        let modified = dir.appendingPathComponent("modified.apk")
        let tamper = #"import zipfile,sys; z=zipfile.ZipFile(sys.argv[1]); w=zipfile.ZipFile(sys.argv[2],'w'); [(w.writestr(n,b'tampered' if n.endswith('.so') else z.read(n))) for n in z.namelist()]; w.close(); z.close()"#
        _ = try ApkUnpacker.run(["/usr/bin/python3", "-c", tamper, apk.path, modified.path])
        XCTAssertEqual(try AndroidAPKSignature.inspect(modified).state, "invalid")
        let registry = LocalAPKVariantStore(root: dir.appendingPathComponent("rejected-variants"))
        XCTAssertThrowsError(try registry.register(from: modified, recipe: batmanRecipe()))
        XCTAssertTrue(registry.variants(for: try batmanRecipe()).isEmpty)
    }

    func testActualRE4RecognizesLocalHashWithoutLearningOrInstalling() throws {
        guard let path = ProcessInfo.processInfo.environment["AVPPLAY_LEARNING_RE4_APK"] else {
            throw XCTSkip("Set AVPPLAY_LEARNING_RE4_APK for the read-only real APK integration check")
        }
        let source = URL(fileURLWithPath: path), dir = try scratch(), recipe = try residentEvilRecipe()
        let registry = LocalAPKVariantStore(root: dir.appendingPathComponent("variants"))
        let variant = try registry.register(from: source, recipe: recipe)
        XCTAssertEqual(variant.package, "com.Armature.VR4")
        XCTAssertEqual(variant.versionCode, "203")
        XCTAssertEqual(variant.size, 67179067)
        XCTAssertEqual(variant.sha256, "46efcabd484e96891c70613694e7504b6fb81c410b724cfb67e78b1c16cece2a")
        XCTAssertTrue(variant.androidSignature?.verified == true)
        XCTAssertFalse(variant.officialAPKHashMatchesRecipe == true)
        XCTAssertFalse(variant.official)
        let again = try registry.register(from: source, recipe: recipe)
        XCTAssertEqual(again.id, variant.id)
        XCTAssertEqual(registry.variants(for: recipe).count, 1)
        let learning = LocalAPKLearningStore(variants: registry)
        XCTAssertTrue(try learning.load(recipe).installations.isEmpty)
        XCTAssertThrowsError(try learning.confirmLearning(variant, recipe: recipe, receiptID: "not-installed"))
    }

    func testPersistedRenamedAPKIsRediscoveredAndPreparedWithoutOriginalLocation() throws {
        let root = try scratch()
        var recipe = try residentEvilRecipe()
        recipe.files = [try XCTUnwrap(recipe.files.first { $0.role == "apk" })]
        recipe.trees = nil
        let external = root.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let created = try makeAPK(in: external, package: recipe.package, versionCode: "203", versionName: "2.3")
        let original = external.appendingPathComponent("My Resident Evil backup - different name.apk")
        try FileManager.default.moveItem(at: created, to: original)
        let registryRoot = root.appendingPathComponent("custom-library")
        let imported = try LocalGameImport().discover(in: external, recipe: recipe)
        XCTAssertEqual(imported.apk?.resolvingSymlinksInPath(), original.resolvingSymlinksInPath())
        let registered = try LocalGameImport().register(imported, recipe: recipe, store: LocalAPKVariantStore(root: registryRoot))
        // Only the fixture original is removed. The registered library copy must be sufficient.
        try FileManager.default.removeItem(at: original)
        let reopened = LocalAPKVariantStore(root: registryRoot)
        let found = try XCTUnwrap(reopened.variants(for: recipe).first { $0.id == registered.id })
        XCTAssertEqual(found.recipeID, recipe.id)
        XCTAssertEqual(found.recipeVersionCode, recipe.versionCode)
        let validated = try reopened.validated(id: found.id, for: recipe)
        XCTAssertTrue(validated.apk.path.hasPrefix(registryRoot.path + "/"))
        XCTAssertNotEqual(validated.apk.lastPathComponent, original.lastPathComponent)
        XCTAssertEqual(try Hashing.sha256(of: validated.apk), registered.sha256)
        let tcRoot = root.appendingPathComponent("fixture-toolchain")
        _ = try Verified850Fixture.workspace(at: tcRoot)
        let content = ContentStore(root: root.appendingPathComponent("empty-official-store"))
        let tree = try LocalAPKPreparer().prepare(recipe: recipe, variantID: found.id, store: content,
            toolchain: Toolchain(root: tcRoot), localVariants: reopened)
        XCTAssertEqual(tree.lastPathComponent, "re4")
        XCTAssertEqual(try Hashing.sha256(of: tcRoot.appendingPathComponent("re4.apk")), found.sha256)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tree.appendingPathComponent("apktool.yml").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
    }

    func testBuildInstallAndResumeReloadSamePersistedVariantAndCustomRegistry() async throws {
        let root = try scratch()
        var recipe = try residentEvilRecipe()
        recipe.files = [try XCTUnwrap(recipe.files.first { $0.role == "apk" })]
        recipe.trees = nil
        let original = try makeAPK(in: root, package: recipe.package, versionCode: "203", versionName: "2.3")
        let registryRoot = root.appendingPathComponent("non-default-registry")
        let variant = try LocalAPKVariantStore(root: registryRoot).register(from: original, recipe: recipe)
        try FileManager.default.removeItem(at: original)
        let jobRoot = root.appendingPathComponent("jobs")
        let content = ContentStore(root: root.appendingPathComponent("empty-official-store"))
        for (index, steps) in [InstallStep.localAPKBuildOnly, InstallStep.localAPKInstall].enumerated() {
            var request = InstallRequest(toolchain: try Verified850Fixture.source().root.path)
            request.localAPKVariantID = variant.id
            request.localVariantStorePath = registryRoot.path
            var job = Job(recipe: recipe, request: request, steps: steps, toolchainCommit: "cc2856c", suffix: "reuse-\(index)")
            job.state = .failed; job.failureKind = .device
            if steps.contains(.fetch) { job.completed = [.fetch] }
            let jobs = JobStore(directory: jobRoot); try jobs.save(job)
            let reopened = JobStore(directory: jobRoot)
            let resumed = try reopened.prepareResume(job.id)
            XCTAssertEqual(resumed.request.localAPKVariantID, variant.id)
            XCTAssertEqual(resumed.request.localVariantStorePath, registryRoot.path)
            let registry = LocalAPKVariantStore(root: URL(fileURLWithPath: try XCTUnwrap(resumed.request.localVariantStorePath)))
            let installer = Installer(recipe: resumed.recipe, request: resumed.request, store: content,
                                      localVariants: registry, report: { _ in })
            // Build and staging obtain input through these production methods; no compiler/device is invoked.
            try installer.buildInputs()
            let selected = try XCTUnwrap(installer.selectedLocalAPK())
            XCTAssertEqual(selected.variant.id, variant.id)
            let files = try installer.localFiles()
            let apk = try XCTUnwrap(files.first { $0.file.role == "apk" })
            XCTAssertEqual(apk.url, selected.apk)
            XCTAssertEqual(apk.file.sha256, variant.sha256)
            XCTAssertEqual(StagePlan.destination(for: apk.file), "Documents/re4.apk")
            let validatedID = LockedBox<String?>(nil)
            _ = try await JobRunner(store: reopened).run(resumed, currentToolchain: "cc2856c") { _, persistedJob in
                let reopenedRegistry = LocalAPKVariantStore(root: URL(fileURLWithPath: persistedJob.request.localVariantStorePath!))
                let input = try reopenedRegistry.validated(id: persistedJob.request.localAPKVariantID!, for: persistedJob.recipe)
                validatedID.set(input.variant.id)
            }
            XCTAssertEqual(validatedID.get(), variant.id)
            XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        }
    }

    func testAutomaticImportRecognizedOfficialLocalAndUnknownHashes() throws {
        let dir = try scratch(), apk = try makeAPK(in: dir)
        var recipe = try batmanRecipe()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let original = try encoder.encode(recipe)
        let store = LocalAPKLearningStore(variants: LocalAPKVariantStore(root: dir.appendingPathComponent("library")))
        let importer = LocalGameImport()
        let unknown = try importer.identify(apk, recipes: [recipe], learning: store)
        XCTAssertFalse(unknown.recognizedHash)
        XCTAssertEqual(unknown.recipe.id, recipe.id)
        XCTAssertEqual(unknown.sha256, try Hashing.sha256(of: apk))
        XCTAssertNil(try store.load(recipe).current, "Import identification must not learn a hash")
        XCTAssertEqual(try encoder.encode(recipe), original)
        let index = try XCTUnwrap(recipe.files.firstIndex { $0.role == "apk" })
        recipe.files[index].sha256 = unknown.sha256
        let official = try importer.identify(dir, recipes: [recipe], learning: store)
        XCTAssertTrue(official.recognizedHash)
        recipe.files[index].sha256 = String(repeating: "0", count: 64)
        let registry = LocalAPKVariantStore(root: dir.appendingPathComponent("registered"))
        let variant = try registry.register(from: apk, recipe: recipe)
        let local = LocalAPKLearningStore(variants: registry)
        try local.authorize(variant, recipe: recipe, allowed: true)
        let installed = LocalAPKInstallation(id: "fixture", variantID: variant.id, sha256: variant.sha256,
            size: variant.size, package: variant.package, versionCode: variant.versionCode,
            bundleID: "test.local", deviceID: "test", team: "TESTTEAM01", toolchain: "fixture", date: Date())
        try local.recordInstallation(installed, variant: variant, recipe: recipe)
        try local.confirmLearning(variant, recipe: recipe, receiptID: installed.id)
        XCTAssertTrue(try importer.identify(apk, recipes: [recipe], learning: local).recognizedHash)
    }

    func testAutomaticImportRejectsWrongVersionAndAmbiguity() throws {
        let dir = try scratch(), apk = try makeAPK(in: dir), recipe = try batmanRecipe()
        let store = LocalAPKLearningStore(variants: LocalAPKVariantStore(root: dir.appendingPathComponent("library")))
        var wrong = recipe; wrong.versionCode += 1
        XCTAssertThrowsError(try LocalGameImport().identify(apk, recipes: [wrong], learning: store))
        var duplicate = recipe; duplicate.id += "-ambiguous"
        XCTAssertThrowsError(try LocalGameImport().identify(apk, recipes: [recipe, duplicate], learning: store))
        let index = try XCTUnwrap(duplicate.files.firstIndex { $0.role == "apk" })
        duplicate.files[index].sha256 = try Hashing.sha256(of: apk)
        XCTAssertEqual(try LocalGameImport().identify(apk, recipes: [recipe, duplicate], learning: store).recipe.id, duplicate.id)
    }

    func testUnknownQuestAPKCreatesSeparateProvisionalRecordAndAssociatesExternalFiles() throws {
        let dir = try scratch(), apk = try makeAPK(in: dir, package: "com.example.newquest", versionCode: "12", versionName: "1.2")
        let official = try batmanRecipe(), encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let officialBefore = try encoder.encode(official)
        let registry = LocalAPKVariantStore(root: dir.appendingPathComponent("variants"))
        XCTAssertThrowsError(try LocalGameImport().identify(apk, recipes: [official],
            learning: LocalAPKLearningStore(variants: registry))) { error in
            XCTAssertTrue("\(error)".contains("Nenhuma receita compatível"))
        }
        let provisionalRoot = dir.appendingPathComponent("provisional-recipes")
        let store = LocalProvisionalRecipeStore(root: provisionalRoot)
        let record = try store.create(from: apk)
        XCTAssertEqual(record.package, "com.example.newquest")
        XCTAssertEqual(record.versionCode, "12")
        XCTAssertEqual(record.versionName, "1.2")
        XCTAssertEqual(record.architectures, ["arm64-v8a"])
        XCTAssertEqual(record.apkSHA256, try Hashing.sha256(of: apk))
        let reopened = try XCTUnwrap(store.loadAll().first)
        XCTAssertEqual(reopened.id, record.id)
        XCTAssertEqual(reopened.package, record.package)
        XCTAssertEqual(reopened.apkSHA256, record.apkSHA256)
        let external = dir.appendingPathComponent("main.12.com.example.newquest.obb")
        try Data(repeating: 0x5a, count: 128).write(to: external)
        let associated = try store.associate([external], with: record.id)
        XCTAssertEqual(associated.externalFiles.map(\.path), [external.path])
        XCTAssertEqual(associated.externalFiles.map(\.size), [128])
        XCTAssertEqual(associated.externalFiles.first?.sha256, try Hashing.sha256(of: external),
                       "external content is associated only with a verified digest")
        XCTAssertEqual(try encoder.encode(official), officialBefore, "Provisional import must not edit existing recipes")
        XCTAssertTrue(record.compatibilityBlockers.contains("Receita Klepton compatível e target verificados"))
    }

    func testGenericExperimentalAPKUses824RecipeAndStagesHashedOBBWithoutChangingOfficialRecipes() throws {
        let dir = try scratch()
        let apk = try makeAPK(in: dir, package: "com.example.generic", versionCode: "12", versionName: "1.2",
                              nativeLibraries: ["libUE4.so"])
        let root = dir.appendingPathComponent("provisional-recipes")
        let provisional = LocalProvisionalRecipeStore(root: root)
        var record = try provisional.create(from: apk)
        XCTAssertNil(record.communityTarget, "generic target is not a fixed per-game exception")
        XCTAssertEqual(record.genericAnalysis.engine, .unreal4)
        XCTAssertTrue(record.genericAnalysis.canAttemptGenericBuild)
        record = try provisional.setExperimentalTarget(appID: "6072194326150034",
            provenance: "synthetic test input", for: record.id)
        var recipe = try XCTUnwrap(record.experimentalRecipe)
        XCTAssertNoThrow(try recipe.validateForJob())
        XCTAssertThrowsError(try recipe.validate())

        let variants = LocalAPKVariantStore(root: dir.appendingPathComponent("variants"))
        let variant = try variants.register(from: apk, recipe: recipe)
        let obb = dir.appendingPathComponent("main.12.com.example.generic.obb")
        try Data(repeating: 0x5a, count: 512).write(to: obb)
        record = try provisional.associate([obb], with: record.id)
        XCTAssertTrue(record.experimentalBlockers.isEmpty)
        let externalAsset = dir.appendingPathComponent("pakchunk1.blob")
        try Data("synthetic-asset".utf8).write(to: externalAsset)
        record = try provisional.associate([externalAsset], with: record.id)
        XCTAssertFalse(record.experimentalBlockers.isEmpty, "an asset has no inferred destination")
        record = try provisional.mapExternalFile(externalAsset.path, kind: "asset",
            destination: "android-files/assets", evidence: "synthetic test mapping", for: record.id)
        XCTAssertTrue(record.experimentalBlockers.isEmpty)
        recipe = try XCTUnwrap(record.experimentalRecipe)
        let updatedVariant = try variants.register(from: apk, recipe: recipe)
        XCTAssertEqual(variant.sha256, updatedVariant.sha256)
        let staged = try provisional.installationExperimentalFiles(variant: updatedVariant, recipe: recipe,
            obbDirectory: "android-files/Android/obb/com.example.generic")
        XCTAssertEqual(staged.map(\.destination), [
            "Documents/android-files/Android/obb/com.example.generic/\(obb.lastPathComponent)",
            "Documents/android-files/assets/pakchunk1.blob"
        ])

        try Data(repeating: 0xff, count: 512).write(to: obb)
        XCTAssertThrowsError(try provisional.installationExperimentalFiles(variant: updatedVariant, recipe: recipe,
            obbDirectory: "android-files/Android/obb/com.example.generic"))
    }

    func testCancelledSupportingFileAnalysisPreservesExistingVariantMetadata() async throws {
        let dir = try scratch()
        var recipe = try batmanRecipe(); recipe.files = recipe.files.filter { $0.role == "apk" }
        let apk = try makeAPK(in: dir), registry = LocalAPKVariantStore(root: dir.appendingPathComponent("variants"))
        let original = try registry.register(from: apk, recipe: recipe)
        let metadata = registry.root.appendingPathComponent("\(recipe.id)-\(recipe.versionCode)/\(original.id).json")
        let before = try Data(contentsOf: metadata)
        let asset = dir.appendingPathComponent("support.obb")
        try Data(repeating: 7, count: 16 << 20).write(to: asset)
        recipe.files.append(RecipeFile(name: "support.obb", role: "obb", id: "support", required: true))
        let found = try LocalGameImport().discover(in: dir, recipe: recipe, selectedAPK: apk)
        let reached = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let frozen = recipe
        let worker = Task.detached {
            try LocalGameImport().register(found, recipe: frozen, store: registry) { progress in
                if progress.phase == "Verificando arquivos adicionais" && progress.done > 0 {
                    reached.signal(); _ = release.wait(timeout: .now() + 5)
                }
            }
        }
        let signalled = await Task.detached { reached.wait(timeout: .now() + 5) == .success }.value
        XCTAssertTrue(signalled)
        worker.cancel(); release.signal()
        do { _ = try await worker.value; XCTFail("Cancelled import must not commit") } catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertEqual(try Data(contentsOf: metadata), before)
        XCTAssertEqual(ContentStore.fileSize(asset), 16 << 20)
        XCTAssertTrue(FileManager.default.fileExists(atPath: apk.path))
    }

    func testAutomaticIdentificationReusesIntegrityCacheWithoutLearningRecipeHash() throws {
        let dir = try scratch(), apk = try makeAPK(in: dir), recipe = try batmanRecipe()
        let registry = LocalAPKVariantStore(root: dir.appendingPathComponent("library"))
        let learning = LocalAPKLearningStore(variants: registry)
        let selection = try LocalGameImport().identify(apk, recipes: [recipe], learning: learning)
        XCTAssertNil(try learning.load(recipe).current)
        guard try SHA256FileCache.identity(apk).reliable else { throw XCTSkip("Requires reliable filesystem identity") }
        let cacheHits = LockedBox(0)
        XCTAssertEqual(try registry.hashCache.digest(apk, progress: { _, _, cached in if cached { cacheHits.update { $0 += 1 } } }), selection.sha256)
        XCTAssertEqual(cacheHits.get(), 1)
    }

    func testPreparationFirstReadReuseMutationAndMissingFiles135() throws {
        let dir = try scratch(), source = try makeAPK(in: dir)
        var recipe = try batmanRecipe()
        recipe.files = recipe.files.filter { $0.role == "apk" }
        let registry = LocalAPKVariantStore(root: dir.appendingPathComponent("registry"))
        let variant = try registry.register(from: source, recipe: recipe)
        let hits = LockedBox(0)
        let first = try registry.validatedForPreparation(id: variant.id, for: recipe) { value in
            if value.cached { hits.update { $0 += 1 } }
        }
        XCTAssertEqual(hits.get(), 0, "Import cache must not satisfy the first preparation")
        let reliable = try SHA256FileCache.identity(first.apk).reliable
        _ = try LocalAPKVariantStore(root: registry.root).validatedForPreparation(id: variant.id, for: recipe) { value in
            if value.cached { hits.update { $0 += 1 } }
        }
        XCTAssertEqual(hits.get(), reliable ? 1 : 0)
        hits.update { $0 = 0 }
        recipe.title += " changed requirement identity"
        _ = try registry.validatedForPreparation(id: variant.id, for: recipe) { value in
            if value.cached { hits.update { $0 += 1 } }
        }
        XCTAssertEqual(hits.get(), 0, "Recipe changes require full validation")
        _ = try registry.validatedForPreparation(id: variant.id, for: recipe, forceFull: true) { value in
            if value.cached { hits.update { $0 += 1 } }
        }
        XCTAssertEqual(hits.get(), 0, "Manual validation must remain uncached")
        let original = try Data(contentsOf: first.apk)
        var changed = original; changed[0] ^= 1
        try changed.write(to: first.apk)
        XCTAssertThrowsError(try registry.validatedForPreparation(id: variant.id, for: recipe))
        try original.write(to: first.apk)
        recipe.files.append(RecipeFile(name: "required.obb", role: "obb", id: "r", size: 4, required: true))
        XCTAssertThrowsError(try registry.validatedForPreparation(id: variant.id, for: recipe)) { error in
            XCTAssertTrue(String(describing: error).contains("required.obb"))
        }
        recipe.files.removeLast()
        try FileManager.default.removeItem(at: first.apk)
        XCTAssertThrowsError(try registry.validatedForPreparation(id: variant.id, for: recipe))
    }

    func testPreparationValidatesAssociatedAssetsAndDirectBuildOnly135() throws {
        let dir = try scratch(), source = try makeAPK(in: dir)
        var recipe = try batmanRecipe()
        let assetURL = dir.appendingPathComponent("main.obb")
        try Data("good".utf8).write(to: assetURL)
        let hash = Hashing.sha256(of: Data("good".utf8))
        recipe.files = recipe.files.filter { $0.role == "apk" }
            + [RecipeFile(name: "main.obb", role: "obb", id: "r", size: 4, sha256: hash, required: true)]
        let registry = LocalAPKVariantStore(root: dir.appendingPathComponent("registry"))
        let asset = LocalAPKAsset(name: "main.obb", sourcePath: assetURL.path, sourceRootPath: dir.path,
            size: 4, sha256: hash, recipeSizeMatches: true)
        let variant = try registry.register(from: source, recipe: recipe, assets: [asset])
        let hits = LockedBox(0)
        _ = try registry.validatedForPreparation(id: variant.id, for: recipe) { value in
            if value.cached { hits.update { $0 += 1 } }
        }
        XCTAssertEqual(hits.get(), 0)
        _ = try registry.validatedForPreparation(id: variant.id, for: recipe) { value in
            if value.cached { hits.update { $0 += 1 } }
        }
        if try SHA256FileCache.identity(assetURL).reliable { XCTAssertEqual(hits.get(), 2) }
        try Data("evil".utf8).write(to: assetURL)
        XCTAssertThrowsError(try registry.validatedForPreparation(id: variant.id, for: recipe))
        try FileManager.default.removeItem(at: assetURL)
        XCTAssertThrowsError(try BuildOnlyPipeline.build(toolchainRoot: try Verified850Fixture.source().root,
            recipe: recipe, store: ContentStore(root: dir.appendingPathComponent("store")),
            localAPKVariantID: variant.id, localVariants: registry, bundleID: "test.game", appVersion: "1", appBuild: "1",
            workspaceRoot: dir.appendingPathComponent("workspaces"))) { error in
                XCTAssertTrue(String(describing: error).contains("main.obb"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("workspaces").path))
    }

    func testPreparationAndInstallEntryPointsRequireInitialValidation135() throws {
        let dir = try scratch(), source = try makeAPK(in: dir)
        var recipe = try batmanRecipe(); recipe.files = recipe.files.filter { $0.role == "apk" }
        let registry = LocalAPKVariantStore(root: dir.appendingPathComponent("install-registry"))
        let variant = try registry.register(from: source, recipe: recipe)
        var request = InstallRequest(toolchain: "/unused")
        request.localAPKVariantID = variant.id
        let hits = LockedBox(0)
        let installer = Installer(recipe: recipe, request: request,
            store: ContentStore(root: dir.appendingPathComponent("store")), localVariants: registry,
            jobs: JobStore(directory: dir.appendingPathComponent("jobs")),
            progress: { if $0.validation?.cached == true { hits.update { $0 += 1 } } }, report: { _ in })
        _ = try installer.selectedLocalAPK(verifyAssetHashes: true, verifyAPKHash: true)
        XCTAssertEqual(hits.get(), 0, "The preparation boundary must pass initial full validation")
        XCTAssertTrue(FileManager.default.fileExists(atPath: registry.root.appendingPathComponent(".preparation-validations/\(variant.id).json").path))
        let prepareRegistry = LocalAPKVariantStore(root: dir.appendingPathComponent("prepare-registry"))
        let prepareVariant = try prepareRegistry.register(from: source, recipe: recipe)
        let tc = dir.appendingPathComponent("toolchain")
        _ = try Verified850Fixture.workspace(at: tc)
        _ = try LocalAPKPreparer().prepare(recipe: recipe, variantID: prepareVariant.id,
            store: ContentStore(root: dir.appendingPathComponent("prepare-store")), toolchain: Toolchain(root: tc), localVariants: prepareRegistry)
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepareRegistry.root.appendingPathComponent(".preparation-validations/\(prepareVariant.id).json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("jobs").path))
    }

    func testSigningMetadataDoesNotRehashAssetsAndTransferStillRejectsCorruption137() throws {
        let dir = try scratch(), source = try makeAPK(in: dir)
        var recipe = try batmanRecipe()
        let assetURL = dir.appendingPathComponent("main.obb"), bytes = Data("good".utf8)
        try bytes.write(to: assetURL)
        let digest = Hashing.sha256(of: bytes)
        recipe.files = recipe.files.filter { $0.role == "apk" }
            + [RecipeFile(name: "main.obb", role: "obb", id: "r", size: 4, sha256: digest, required: true)]
        let registry = LocalAPKVariantStore(root: dir.appendingPathComponent("registry"))
        let variant = try registry.register(from: source, recipe: recipe, assets: [LocalAPKAsset(name: "main.obb",
            sourcePath: assetURL.path, sourceRootPath: dir.path, size: 4, sha256: digest, recipeSizeMatches: true)])
        var request = InstallRequest(toolchain: "/unused"); request.localAPKVariantID = variant.id
        let externalHashEvents = LockedBox(0)
        let installer = Installer(recipe: recipe, request: request, store: ContentStore(root: dir.appendingPathComponent("store")),
            localVariants: registry, jobs: JobStore(directory: dir.appendingPathComponent("jobs")), progress: { value in
                if value.validation?.file == "main.obb" { externalHashEvents.update { $0 += 1 } }
            }, report: { _ in })
        _ = try installer.selectedLocalAPK(verifyAssetHashes: true)
        XCTAssertGreaterThan(externalHashEvents.get(), 0, "Initial preparation must read external content")
        externalHashEvents.update { $0 = 0 }
        for _ in 0..<6 { _ = try installer.selectedLocalAPK() }
        XCTAssertEqual(externalHashEvents.get(), 0, "Readiness checks must not reread OBBs")
        try Data("evil".utf8).write(to: assetURL)
        _ = try installer.selectedLocalAPK()
        let cache = SHA256FileCache(root: dir.appendingPathComponent("transfer-cache"))
        XCTAssertThrowsError(try InstallationContent.entry(source: assetURL, destination: "Documents/obb/main.obb", expectedHash: digest, cache: cache))
        try FileManager.default.removeItem(at: assetURL)
        XCTAssertThrowsError(try installer.selectedLocalAPK())
    }

    func testReuseOnlyMissingArtifactFailsBeforeExternalHashing137() async throws {
        let dir = try scratch(), source = try makeAPK(in: dir)
        var recipe = try batmanRecipe(); recipe.files = recipe.files.filter { $0.role == "apk" }
        let registry = LocalAPKVariantStore(root: dir.appendingPathComponent("registry"))
        let variant = try registry.register(from: source, recipe: recipe)
        let tc = dir.appendingPathComponent("toolchain")
        let verified = try Verified850Fixture.source()
        var request = InstallRequest(toolchain: verified.root.path); request.localAPKVariantID = variant.id
        request.reuseBuildOnly = true; request.localWorkspaceRoot = dir.appendingPathComponent("workspaces").path
        let jobs = JobStore(directory: dir.appendingPathComponent("jobs"))
        let installer = Installer(recipe: recipe, request: request, store: ContentStore(root: dir.appendingPathComponent("store")),
            localVariants: registry, jobs: jobs, report: { _ in })
        do { try await installer.perform(.fetch); XCTFail("Must refuse automatic rebuilding") }
        catch { XCTAssertTrue(String(describing: error).contains("recompilação automática bloqueada")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: registry.root.appendingPathComponent(".preparation-validations").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: request.localWorkspaceRoot!))
        XCTAssertTrue(jobs.all().isEmpty)
    }

    func testInstalledBundleMismatchBlocksWithoutChangingIdentifiers137() throws {
        let old = InstalledApp(bundleIdentifier: "marceloberger.dev.klepton.target.batman", name: "Arkham Shadow", version: "1.0", bundleVersion: "1")
        XCTAssertThrowsError(try Installer.requireMatchingInstalledBundle(apps: [old], expected: "marceloberger.bb7g7a8fsp.dev.klepton.target.batman", target: "batman"))
        XCTAssertNoThrow(try Installer.requireMatchingInstalledBundle(apps: [old], expected: old.bundleIdentifier, target: "batman"))
        XCTAssertNoThrow(try Installer.requireMatchingInstalledBundle(apps: [], expected: old.bundleIdentifier, target: "batman"))
    }

    private final class CacheReadMeter: @unchecked Sendable {
        let path: String
        private let lock = NSLock()
        private var passes = 0, bytes: Int64 = 0, last: Int64 = 0
        init(_ file: URL) { path = file.resolvingSymlinksInPath().path }
        func observe(_ file: URL, _ done: Int64) {
            guard file.resolvingSymlinksInPath().path == path else { return }
            lock.lock(); defer { lock.unlock() }
            if done == 0 { passes += 1; last = 0 }
            else { bytes += max(0, done - last); last = done }
        }
        func reset() { lock.lock(); defer { lock.unlock() }; passes = 0; bytes = 0; last = 0 }
        func counts() -> (Int, Int64) { lock.lock(); defer { lock.unlock() }; return (passes, bytes) }
    }
    private struct CacheFlowFixture {
        var root: URL, asset: URL, recipe: Recipe, registry: LocalAPKVariantStore, variant: LocalAPKVariant
        var toolchain: Toolchain, meter: CacheReadMeter, untrusted: Bool
        func reopened() -> LocalAPKVariantStore {
            let cache = SHA256FileCache(root: registry.hashCache.root,
                unreliablePaths: untrusted ? [asset.resolvingSymlinksInPath().path] : [],
                contentReadObserver: { meter.observe($0, $1) })
            return LocalAPKVariantStore(root: registry.root, hashCache: cache)
        }
        func installer(_ registry: LocalAPKVariantStore? = nil) -> Installer {
            var request = InstallRequest(toolchain: toolchain.root.path); request.localAPKVariantID = variant.id
            return Installer(recipe: recipe, request: request, store: ContentStore(root: root.appendingPathComponent("store")),
                localVariants: registry ?? self.registry, jobs: JobStore(directory: root.appendingPathComponent("jobs")), report: { _ in })
        }
    }
    private func cacheFlowFixture(untrusted: Bool) throws -> CacheFlowFixture {
        let root = try scratch(), source = try makeAPK(in: root), asset = root.appendingPathComponent("main.obb")
        let data = Data(repeating: 7, count: 1 << 20); try data.write(to: asset)
        var recipe = try batmanRecipe(); recipe.assetFiles = nil; recipe.trees = nil
        recipe.files = recipe.files.filter { $0.role == "apk" } + [RecipeFile(name: "main.obb", role: "obb", id: "1",
            size: Int64(data.count), sha256: Hashing.sha256(of: data), required: true)]
        let meter = CacheReadMeter(asset), library = root.appendingPathComponent("library")
        let cache = SHA256FileCache(root: library.appendingPathComponent(".sha256-cache"),
            unreliablePaths: untrusted ? [asset.resolvingSymlinksInPath().path] : [], contentReadObserver: { meter.observe($0, $1) })
        let registry = LocalAPKVariantStore(root: library, hashCache: cache)
        let variant = try registry.register(from: source, recipe: recipe, assets: [LocalAPKAsset(name: "main.obb",
            sourcePath: asset.path, sourceRootPath: root.path, size: Int64(data.count), sha256: Hashing.sha256(of: data), recipeSizeMatches: true)])
        let tc = root.appendingPathComponent("toolchain")
        _ = try Verified850Fixture.workspace(at: tc)
        meter.reset()
        return CacheFlowFixture(root: root, asset: asset, recipe: recipe, registry: registry, variant: variant,
            toolchain: try Toolchain(root: tc), meter: meter, untrusted: untrusted)
    }

    func testPrepareToBuildOnlyCountsActualReads138() throws {
        for untrusted in [false, true] {
            let f = try cacheFlowFixture(untrusted: untrusted)
            XCTAssertTrue(try SHA256FileCache.identity(f.asset).reliable, "APFS fixture identity is required")
            let prepared = try LocalAPKPreparer().prepare(recipe: f.recipe, variantID: f.variant.id,
                store: ContentStore(root: f.root.appendingPathComponent("store")), toolchain: f.toolchain, localVariants: f.registry)
            XCTAssertEqual(f.meter.counts().0, 1); XCTAssertEqual(f.meter.counts().1, 1 << 20)
            let stamp = try Data(contentsOf: prepared.appendingPathComponent(".qi-prepared"))
            f.meter.reset()
            // This is the real validation boundary called at the start of Installer.buildOnly.
            _ = try f.installer().selectedLocalAPK(verifyAssetHashes: true)
            try f.toolchain.prepare(recipe: f.recipe, store: ContentStore(root: f.root.appendingPathComponent("store")),
                localAPKVariantID: f.variant.id, localVariants: f.registry, verifyLocalAssetHashes: false)
            XCTAssertEqual(f.meter.counts().0, untrusted ? 1 : 0)
            XCTAssertEqual(f.meter.counts().1, untrusted ? 1 << 20 : 0)
            XCTAssertEqual(try Data(contentsOf: prepared.appendingPathComponent(".qi-prepared")), stamp)
            let log = try String(contentsOf: f.registry.hashCache.root.appendingPathComponent("validation.log"))
            XCTAssertTrue(log.contains(untrusted ? "não fornece evidência suficiente" : "Reutilizando validação anterior"))
            print("CACHE138 Prepare→BuildOnly \(untrusted ? "NTFS policy" : "APFS"): external passes=\(f.meter.counts().0), bytes=\(f.meter.counts().1)")
        }
    }

    func testRestartPersistsReceiptAndRefusesUnprovenNTFSReuse138() throws {
        for untrusted in [false, true] {
            let f = try cacheFlowFixture(untrusted: untrusted)
            _ = try f.registry.validatedForPreparation(id: f.variant.id, for: f.recipe)
            let receipt = f.registry.root.appendingPathComponent(".preparation-validations/\(f.variant.id).json")
            XCTAssertTrue(FileManager.default.fileExists(atPath: receipt.path))
            f.meter.reset()
            let reopened = f.reopened()
            _ = try f.installer(reopened).selectedLocalAPK(verifyAssetHashes: true)
            XCTAssertEqual(f.meter.counts().0, untrusted ? 1 : 0)
            XCTAssertEqual(f.meter.counts().1, untrusted ? 1 << 20 : 0)
            print("CACHE138 restart \(untrusted ? "NTFS policy" : "APFS"): external passes=\(f.meter.counts().0), bytes=\(f.meter.counts().1)")
        }
    }

    func testManualRecipeCorruptionAndMissingInputsInvalidateCache138() throws {
        let f = try cacheFlowFixture(untrusted: false)
        _ = try f.registry.validatedForPreparation(id: f.variant.id, for: f.recipe)
        f.meter.reset()
        _ = try f.registry.validatedForPreparation(id: f.variant.id, for: f.recipe, forceFull: true)
        XCTAssertEqual(f.meter.counts().0, 1)
        let log = try String(contentsOf: f.registry.hashCache.root.appendingPathComponent("validation.log"))
        XCTAssertTrue(log.contains("manual solicitada explicitamente"))
        f.meter.reset(); var changed = f.recipe; changed.title += " changed"
        _ = try f.registry.validatedForPreparation(id: f.variant.id, for: changed)
        XCTAssertEqual(f.meter.counts().0, 1)
        let oldDate = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: f.asset.path)[.modificationDate] as? Date)
        try Data(repeating: 9, count: 1 << 20).write(to: f.asset)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: f.asset.path)
        f.meter.reset()
        XCTAssertThrowsError(try f.registry.validatedForPreparation(id: f.variant.id, for: changed))
        XCTAssertEqual(f.meter.counts().0, 1)
        try FileManager.default.removeItem(at: f.asset); f.meter.reset()
        XCTAssertThrowsError(try f.registry.validatedForPreparation(id: f.variant.id, for: changed))
        XCTAssertEqual(f.meter.counts().0, 0)
    }

    func testBuildOnlyToInstallFetchReadsNoExternalContent138() async throws {
        let f = try cacheFlowFixture(untrusted: true)
        _ = try f.registry.validatedForPreparation(id: f.variant.id, for: f.recipe)
        let fBuild = try Verified850Fixture.build(root: f.root, recipe: f.recipe,
            variant: f.variant, bundle: "test.cache.batman", workspaceRoot: f.root.appendingPathComponent("workspaces"))
        let app = fBuild.app, jobs = fBuild.jobs, job = fBuild.job
        var request = fBuild.request
        let original = try Data(contentsOf: jobs.url(job.id))
        request.reuseBuildOnly = true; f.meter.reset()
        let installer = Installer(recipe: f.recipe, request: request, store: ContentStore(root: f.root.appendingPathComponent("store")),
            localVariants: f.registry, jobs: jobs, report: { print("CACHE138 reuse: " + $0) })
        XCTAssertEqual(jobs.all().count, 1, "The frozen fixture Job must pass recipe validation")
        try await installer.perform(.fetch)
        XCTAssertEqual(try installer.requirePreservedLocalBuild().app.resolvingSymlinksInPath().path,
                       app.resolvingSymlinksInPath().path)
        XCTAssertEqual(f.meter.counts().0, 0); XCTAssertEqual(f.meter.counts().1, 0)
        XCTAssertEqual(try Data(contentsOf: jobs.directory.appendingPathComponent(job.id + ".json")), original)
        print("CACHE138 BuildOnly→Install readiness: external passes=0, bytes=0; no signer/compiler/device invoked")
        // Content transfer remains a separate integrity boundary: changed bytes must be rejected.
        try Data(repeating: 8, count: 1 << 20).write(to: f.asset)
        XCTAssertThrowsError(try InstallationContent.entry(source: f.asset, destination: "Documents/obb/main.obb",
            expectedHash: f.variant.assets!.first!.sha256, cache: f.registry.hashCache))
        XCTAssertEqual(f.meter.counts().0, 1)
    }

    func makeAPK(in dir: URL, package: String = "com.camouflaj.manta",
                         versionCode: String = "350961", versionName: String = "1.4.1-350961",
                         nativeLibraries: [String] = ["libmain.so"]) throws -> URL {
        let content = dir.appendingPathComponent("synthetic-apk", isDirectory: true)
        let lib = content.appendingPathComponent("lib/arm64-v8a", isDirectory: true)
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        try manifest(package: package, versionCode: versionCode, versionName: versionName)
            .write(to: content.appendingPathComponent("AndroidManifest.xml"))
        for name in nativeLibraries { try Data([0x7f, 0x45, 0x4c, 0x46]).write(to: lib.appendingPathComponent(name)) }
        let apk = dir.appendingPathComponent("synthetic.apk")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-q", "-r", apk.path, "."]
        zip.currentDirectoryURL = content
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)
        return apk
    }

    private func manifest(package: String, versionCode: String, versionName: String) -> Data {
        let strings = ["manifest", "package", package, "versionCode", versionCode,
                       "versionName", versionName, "application"]
        func index(_ value: String) -> UInt32 { UInt32(strings.firstIndex(of: value)!) }
        func u16(_ value: Int) -> Data { withUnsafeBytes(of: UInt16(value).littleEndian) { Data($0) } }
        func u32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        func chunk(_ type: Int, headerSize: Int, _ body: Data) -> Data {
            u16(type) + u16(headerSize) + u32(UInt32(8 + body.count)) + body
        }
        var offsets = Data(), pool = Data()
        for value in strings {
            offsets += u32(UInt32(pool.count))
            let bytes = Data(value.utf8)
            pool += Data([UInt8(value.count), UInt8(bytes.count)]) + bytes + Data([0])
        }
        while pool.count % 4 != 0 { pool.append(0) }
        let stringsStart = 28 + offsets.count
        let poolChunk = chunk(0x0001, headerSize: 28,
                              u32(UInt32(strings.count)) + u32(0) + u32(0x100) + u32(UInt32(stringsStart)) + u32(0) + offsets + pool)
        let none: UInt32 = 0xFFFF_FFFF
        func start(_ tag: String, _ attrs: [(String, String)] = []) -> Data {
            var body = u32(0) + u32(none) + u32(none) + u32(index(tag)) + u16(20) + u16(20)
                + u16(attrs.count) + u16(0) + u16(0) + u16(0)
            for (key, value) in attrs {
                body += u32(none) + u32(index(key)) + u32(index(value)) + u16(8) + Data([0, 0x03]) + u32(index(value))
            }
            return chunk(0x0102, headerSize: 16, body)
        }
        func end(_ tag: String) -> Data { chunk(0x0103, headerSize: 16, u32(0) + u32(none) + u32(none) + u32(index(tag))) }
        let tree = start("manifest", [("package", package), ("versionCode", versionCode),
                                      ("versionName", versionName)])
            + start("application") + end("application") + end("manifest")
        let body = poolChunk + tree
        return u16(0x0003) + u16(8) + u32(UInt32(8 + body.count)) + body
    }
}
