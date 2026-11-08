import XCTest
@testable import AVPPlayCore

final class OptionalAssets173Tests: XCTestCase {
    func testDeadpoolHas53PublishedAssetsAndPTBRNamesAreClassifiedForReview() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let recipe = try RecipeStore(directory: root.appendingPathComponent("recipes")).load(id: "store-3240283705987790")
        XCTAssertEqual(recipe.files.filter { $0.role != "apk" && $0.required }.count, 53)
        XCTAssertEqual(LocalGameImport.classification(URL(fileURLWithPath: "global_localize_PTBR_P.pak")), "Asset de jogo")
        XCTAssertEqual(LocalGameImport.classification(URL(fileURLWithPath: "br.png")), "Textura/imagem")
    }

    func testImportSelectionStagesAndTransfersExtrasWithoutDroppingRequiredFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("optional173-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var recipe = try CommunityAPKStage152Tests().frozenRecipe()
        recipe.id = "optional173-fixture"; recipe.package = "com.test.optional"; recipe.versionCode = 1173
        let apk = try LocalAPKVariantTests().makeAPK(in: root, package: recipe.package, versionCode: "1173", versionName: recipe.versionName)
        func add(_ name: String, role: String, required: Bool, dest: String) throws {
            let bytes = Data("fixture bytes for \(name)".utf8), path = root.appendingPathComponent(name)
            try bytes.write(to: path)
            recipe.files.append(RecipeFile(name: name, role: role, id: "fixture-\(name)", size: Int64(bytes.count),
                sha256: Hashing.sha256(of: bytes), required: required, dest: dest))
        }
        let obbDest = "android-files/Android/obb/\(recipe.package)"
        try add("main.obb", role: "obb", required: true, dest: obbDest)
        try add("known.lang", role: "asset", required: false, dest: obbDest)
        let pak = root.appendingPathComponent("global_localize_PTBR_P.pak")
        let png = root.appendingPathComponent("br.png")
        try Data("pak bytes".utf8).write(to: pak); try Data("png bytes".utf8).write(to: png)
        try Data("save".utf8).write(to: root.appendingPathComponent("progress.sav"))
        try Data("log".utf8).write(to: root.appendingPathComponent("crash.log"))

        let discovery = try LocalGameImport().discover(in: root, recipe: recipe, selectedAPK: apk)
        XCTAssertTrue(discovery.missingRequired.isEmpty)
        XCTAssertEqual(Set(discovery.unmatchedFiles.map(\.lastPathComponent)), ["global_localize_PTBR_P.pak", "br.png"])
        XCTAssertEqual(Set(discovery.ignoredFiles.map(\.lastPathComponent)), ["progress.sav", "crash.log", "AndroidManifest.xml", "libmain.so"])

        let destinations = [pak.path: "android-files/Android/obb/\(recipe.package)/global_localize_PTBR_P.pak",
                            png.path: "android-files/Android/obb/\(recipe.package)/br.png"]
        let review = try LocalGameImport().reviewAdditionalFiles([pak, png], recipe: recipe)
        XCTAssertEqual(Set(review.map(\.origin)), Set(destinations.keys))
        for item in review {
            XCTAssertEqual(item.sha256, try Hashing.sha256(of: URL(fileURLWithPath: item.origin)))
            XCTAssertEqual(item.suggestedDestination, destinations[item.origin])
            XCTAssertEqual(item.size, ContentStore.fileSize(URL(fileURLWithPath: item.origin)))
        }
        let store = LocalAPKVariantStore(root: root.appendingPathComponent("registry"))
        let expectedHashes = Dictionary(uniqueKeysWithValues: review.map { ($0.origin, $0.sha256) })
        let variant = try LocalGameImport().register(discovery, recipe: recipe, store: store,
            additionalDestinations: destinations, expectedAdditionalHashes: expectedHashes)
        try LocalAPKVariantStore.requireCompatibleDependencies(variant, recipe: recipe)
        XCTAssertEqual(variant.assets?.filter { $0.isAdditional == true }.count, 2)
        let sourceByName = Dictionary(uniqueKeysWithValues: (variant.assets ?? []).map { ($0.name, URL(fileURLWithPath: $0.sourcePath)) })
        let apkFile = try XCTUnwrap(recipe.files.first { $0.role == "apk" })
        var staged: [(file: RecipeFile, url: URL, size: Int64)] = [(apkFile, apk, ContentStore.fileSize(apk)!)]
        for file in recipe.files where file.role != "apk" {
            let asset = try XCTUnwrap(variant.assets?.first { $0.name == file.name })
            staged.append((file, URL(fileURLWithPath: asset.sourcePath), asset.size))
        }
        for asset in variant.assets ?? [] where asset.isAdditional == true {
            let file = try asset.additionalRecipeFile()
            staged.append((file, URL(fileURLWithPath: asset.sourcePath), asset.size))
        }
        let entries = try InstallationContent.recipeEntries(recipe: recipe, local: staged,
            cache: SHA256FileCache(root: root.appendingPathComponent("hash-cache")))
        let plan = StagePlan.plan(local: staged, remote: [:])
        XCTAssertEqual(Set(plan.map(\.destination)), Set(entries.map(\.destination)))
        XCTAssertTrue(plan.contains { $0.destination == "Documents/\(destinations[pak.path]!)" })
        XCTAssertTrue(plan.contains { $0.destination == "Documents/\(destinations[png.path]!)" })
        XCTAssertTrue(plan.contains { $0.destination == "Documents/\(obbDest)/main.obb" })

        var remote: [String: Data] = [:]
        let receipts = root.appendingPathComponent("transfer/receipts.json")
        let container = InstallationContent.Container(stat: { path in
            guard let bytes = remote[path] else { return nil }
            return RemoteFile(relativePath: (path as NSString).lastPathComponent, size: Int64(bytes.count), isDirectory: false, modified: Date(timeIntervalSince1970: 1))
        }, fetch: { path, destination in
            guard let bytes = remote[path] else { throw LocalAPKVariantError.missing(path) }
            try bytes.write(to: destination)
        }, put: { source, destination in remote[destination] = try Data(contentsOf: source) })
        try InstallationContent.sync(entries, container: container, receipts: receipts)
        XCTAssertEqual(Set(remote.keys), Set(entries.map(\.destination)))
        for entry in entries { XCTAssertEqual(Hashing.sha256(of: remote[entry.destination]!), entry.sha256) }
        XCTAssertTrue(sourceByName["main.obb"] != nil)
    }

    func testDeadpoolPTBRFilesAreAutomaticallyIncludedInOBBAndManifestWithRequiredAssetsIntact() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("deadpool175-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var recipe = try RecipeStore(directory: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("recipes"))
            .load(id: "store-3240283705987790")
        for index in recipe.files.indices {
            recipe.files[index].size = nil
            recipe.files[index].sha256 = nil
        }
        let apk = try LocalAPKVariantTests().makeAPK(in: root, package: recipe.package,
            versionCode: String(recipe.versionCode), versionName: recipe.versionName)
        for file in recipe.files where file.role != "apk" && file.required {
            try Data("required fixture \(file.name)".utf8).write(to: root.appendingPathComponent(file.name))
        }
        let pak = root.appendingPathComponent("global_localize_PTBR_P.pak")
        let png = root.appendingPathComponent("br.png")
        try Data("PT-BR pak bytes".utf8).write(to: pak)
        try Data("PT-BR image bytes".utf8).write(to: png)
        try Data("unknown".utf8).write(to: root.appendingPathComponent("mystery.bin"))
        try Data("save".utf8).write(to: root.appendingPathComponent("PILO_SaveGameState_AES_X.sav"))
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("shader cache".utf8).write(to: cache.appendingPathComponent("vulkan.cache"))
        try Data("log".utf8).write(to: root.appendingPathComponent("crash.log"))

        let importer = LocalGameImport()
        let discovery = try importer.discover(in: root, recipe: recipe, selectedAPK: apk)
        XCTAssertTrue(discovery.missingRequired.isEmpty)
        XCTAssertEqual(recipe.files.filter(\.required).count, 54)
        XCTAssertEqual(discovery.unmatchedFiles.map(\.lastPathComponent).sorted(),
                       ["br.png", "global_localize_PTBR_P.pak", "mystery.bin"])
        XCTAssertTrue(Set(discovery.ignoredFiles.map(\.lastPathComponent)).isSuperset(of:
            ["PILO_SaveGameState_AES_X.sav", "vulkan.cache", "crash.log"]))

        let automatic = importer.automaticAdditionalDestinations(for: discovery, recipe: recipe)
        let expectedOBB = "android-files/Android/obb/com.twistedpixelgames.PILO"
        XCTAssertEqual(automatic[pak.path], "\(expectedOBB)/global_localize_PTBR_P.pak")
        XCTAssertEqual(automatic[png.path], "\(expectedOBB)/br.png")
        XCTAssertNil(automatic[root.appendingPathComponent("mystery.bin").path])

        let store = LocalAPKVariantStore(root: root.appendingPathComponent("registry"))
        let variant = try importer.register(discovery, recipe: recipe, store: store,
            additionalDestinations: automatic, automaticAdditionalPaths: Set(automatic.keys))
        try LocalAPKVariantStore.requireCompatibleDependencies(variant, recipe: recipe)
        XCTAssertFalse(variant.official)
        XCTAssertFalse(variant.recipeValidated)
        XCTAssertEqual(variant.assets?.filter { $0.isAdditional == true }.count, 2)
        XCTAssertEqual(variant.assets?.filter { $0.automaticallyIncluded == true }.count, 2)
        XCTAssertEqual(variant.assets?.filter { $0.isAdditional != true }.count, 53)
        for name in ["global_localize_PTBR_P.pak", "br.png"] {
            let asset = try XCTUnwrap(variant.assets?.first { $0.origin?.hasSuffix("/\(name)") == true })
            XCTAssertEqual(asset.destination, "\(expectedOBB)/\(name)")
            XCTAssertEqual(asset.sha256, try Hashing.sha256(of: URL(fileURLWithPath: asset.sourcePath)))
            XCTAssertEqual(asset.classification, LocalGameImport.classification(URL(fileURLWithPath: name)))
        }
        let requiredNames = Set(recipe.files.filter { $0.required && $0.role != "apk" }.map(\.name))
        XCTAssertEqual(Set(variant.assets?.filter { $0.isAdditional != true }.map(\.name) ?? []), requiredNames)

        var staged: [(file: RecipeFile, url: URL, size: Int64)] = []
        let apkFile = try XCTUnwrap(recipe.files.first { $0.role == "apk" })
        staged.append((apkFile, apk, ContentStore.fileSize(apk)!))
        for asset in variant.assets ?? [] {
            let file = asset.isAdditional == true ? try asset.additionalRecipeFile() : try XCTUnwrap(recipe.files.first { $0.name == asset.name })
            staged.append((file, URL(fileURLWithPath: asset.sourcePath), asset.size))
        }
        let stage = StagePlan.plan(local: staged, remote: [:])
        for name in ["global_localize_PTBR_P.pak", "br.png"] {
            let item = try XCTUnwrap(stage.first { $0.destination == "Documents/\(expectedOBB)/\(name)" })
            XCTAssertEqual(try Hashing.sha256(of: item.source), try Hashing.sha256(of: root.appendingPathComponent(name)))
        }
        let manifest = try InstallationContent.recipeEntries(recipe: recipe, local: staged,
            cache: SHA256FileCache(root: root.appendingPathComponent("manifest-cache")))
        for name in ["global_localize_PTBR_P.pak", "br.png"] {
            let entry = try XCTUnwrap(manifest.first { $0.destination == "Documents/\(expectedOBB)/\(name)" })
            XCTAssertEqual(entry.sha256, try Hashing.sha256(of: entry.source))
        }
        let originalAssetsHash = try LocalAPKBuildEvidence.assetsHash(variant)
        var changed = variant
        let extraIndex = try XCTUnwrap(changed.assets?.firstIndex { $0.isAdditional == true })
        changed.assets![extraIndex].destination = "android-files/other-location/\(changed.assets![extraIndex].name)"
        XCTAssertNotEqual(try LocalAPKBuildEvidence.assetsHash(changed), originalAssetsHash,
                          "Changing an extra's destination must invalidate reused Build evidence")
        changed = variant
        changed.assets?.removeAll { $0.isAdditional == true }
        XCTAssertNotEqual(try LocalAPKBuildEvidence.assetsHash(changed), originalAssetsHash,
                          "Changing the selected extra set must invalidate reused Build evidence")
        let persisted = try XCTUnwrap(store.variants(for: recipe).first { $0.id == variant.id })
        XCTAssertEqual(persisted.assets?.filter { $0.automaticallyIncluded == true }.count, 2)
        XCTAssertEqual(persisted.assets?.filter { $0.isAdditional == true }.map(\.sha256).sorted(),
                       variant.assets?.filter { $0.isAdditional == true }.map(\.sha256).sorted())
    }

    func testGenericAutomaticDestinationUsesRecipeAndLeavesAmbiguousOrUnknownExtrasPending() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("generic-extra175-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var recipe = try CommunityAPKStage152Tests().frozenRecipe()
        recipe.package = "com.test.generic175"
        recipe.files = recipe.files.map { file in
            var copy = file; copy.size = nil; copy.sha256 = nil
            if copy.role != "apk" { copy.dest = "android-files/Android/obb/\(recipe.package)" }
            return copy
        }
        let obbName = "main.obb"
        recipe.files.append(RecipeFile(name: obbName, role: "obb", id: "fixture-obb", size: nil,
            sha256: nil, required: true, dest: "android-files/Android/obb/\(recipe.package)"))
        let apk = try LocalAPKVariantTests().makeAPK(in: root, package: recipe.package,
            versionCode: String(recipe.versionCode), versionName: recipe.versionName)
        for file in recipe.files where file.role != "apk" && file.required {
            try Data("fixture \(file.name)".utf8).write(to: root.appendingPathComponent(file.name))
        }
        let audio = root.appendingPathComponent("extra.ogg")
        let unknown = root.appendingPathComponent("unknown.bin")
        let splitAPK = root.appendingPathComponent("split_config.arm64.apk")
        try Data("audio".utf8).write(to: audio); try Data("unknown".utf8).write(to: unknown)
        try Data("split apk".utf8).write(to: splitAPK)
        let discovery = try LocalGameImport().discover(in: root, recipe: recipe, selectedAPK: apk)
        let automatic = LocalGameImport().automaticAdditionalDestinations(for: discovery, recipe: recipe)
        XCTAssertEqual(automatic[audio.path], "android-files/Android/obb/\(recipe.package)/extra.ogg")
        XCTAssertNil(automatic[unknown.path])
        XCTAssertTrue(discovery.unmatchedFiles.contains { $0.lastPathComponent == splitAPK.lastPathComponent })
        XCTAssertNil(automatic[splitAPK.path], "An extra APK must be reviewed, not copied into OBB automatically")

        var ambiguous = recipe
        ambiguous.files[ambiguous.files.count - 1].name = "payload.dat"
        ambiguous.files[ambiguous.files.count - 1].role = "asset"
        ambiguous.files.append(RecipeFile(name: "alternate.dat", role: "asset", id: "fixture-alt", size: nil,
            sha256: nil, required: false, dest: "android-files/alternate-assets"))
        for index in ambiguous.files.indices where ambiguous.files[index].role != "apk" {
            ambiguous.files[index].dest = "android-files/asset-\(index)"
        }
        let ambiguousDiscovery = try LocalGameImport().discover(in: root, recipe: ambiguous, selectedAPK: apk)
        XCTAssertTrue(LocalGameImport().automaticAdditionalDestinations(for: ambiguousDiscovery, recipe: ambiguous).isEmpty)
    }
}
