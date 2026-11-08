import XCTest
@testable import AVPPlayCore

final class FolderAnalysis184Tests: XCTestCase {
    private let package = "com.example.folder184"
    private func fixture() throws -> (URL, URL, URL) {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("folder184-\(UUID())")
        let input = root.appendingPathComponent("input")
        let staging = root.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let apk = try LocalAPKVariantTests().makeAPK(in: staging, package: package,
            versionCode: "47", versionName: "1.3.1", nativeLibraries: ["libUE4.so"])
        let selected = input.appendingPathComponent("base.apk")
        try FileManager.default.copyItem(at: apk, to: selected)
        return (root, input, selected)
    }
    @discardableResult
    private func file(_ path: String, in root: URL, text: String = "payload") throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }
    private func recipe(apk: URL) -> Recipe {
        Recipe(schema: 1, id: "folder184", title: "Fixture", package: package, versionName: "1.3.1", versionCode: 47,
            store: .init(appId: "123456"), toolchain: .init(target: "x123456", minCommit: "cc2856c"),
            files: [.init(name: "base.apk", role: "apk", id: "apk", required: true, dest: "", localName: "x123456.apk"),
                    .init(name: "main.47.\(package).obb", role: "obb", id: "obb", required: true, dest: "Documents/android-files/Android/obb/\(package)")],
            addons: nil, status: .init(playability: "untested", download: "unknown", notes: nil), icon: nil)
    }
    func testFolderWithoutRecipeSavesAPKOBBsAndUnknownAssetsForReview() throws {
        let (root, input, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let main = try file("Android/obb/\(package)/main.47.\(package).obb", in: input)
        let patch = try file("Android/obb/\(package)/patch.47.\(package).obb", in: input)
        let asset = try file("assets/extra.pak", in: input)
        let unknown = try file("unclassified.dat", in: input)
        try file("Saved/progress.sav", in: input); try file("Logs/debug.log", in: input)
        let store = LocalProvisionalRecipeStore(root: root.appendingPathComponent("provisional"))
        let discovery = try LocalGameImport().discover(in: input)
        XCTAssertFalse(discovery.canInstall)
        let record = try LocalGameImport().createProvisionalAnalysis(from: input, store: store)
        XCTAssertEqual(record.genericAnalysis.engine, .unreal4)
        XCTAssertEqual(record.genericAnalysis.entrypoint, "libUE4")
        XCTAssertEqual(Set(record.externalFiles.map(\.path)), Set([main, patch, asset, unknown].map { $0.path }))
        XCTAssertTrue(record.externalFiles.allSatisfy { $0.sha256 != nil && $0.destination == nil })
        XCTAssertNil(record.experimentalRecipe)
        XCTAssertEqual(try store.loadAll(), [record])
    }
    func testIncompleteRecordIsReusedWithoutCopiesDuplicatesOrRewritingReview() throws {
        let (root, input, apk) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let external = try file("extra.pak", in: input)
        let store = LocalProvisionalRecipeStore(root: root.appendingPathComponent("provisional"))
        let importer = LocalGameImport()
        let first = try importer.createProvisionalAnalysis(from: input, store: store)
        let json = store.root.appendingPathComponent(first.id + ".json")
        let original = try Data(contentsOf: json)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: json.path)
        let hashes = try [apk, external].map { try Hashing.sha256(of: $0) }
        let again = try importer.createProvisionalAnalysis(from: input, store: store)
        XCTAssertEqual(again, first); XCTAssertEqual(again.externalFiles.count, 1)
        XCTAssertEqual(try Data(contentsOf: json), original)
        XCTAssertEqual(try json.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date)
        XCTAssertEqual(try [apk, external].map { try Hashing.sha256(of: $0) }, hashes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("local-variants").path))
        let newAsset = try file("new.pak", in: input)
        let merged = try importer.createProvisionalAnalysis(from: input, store: store)
        XCTAssertEqual(merged.createdAt, first.createdAt)
        XCTAssertEqual(Set(merged.externalFiles.map(\.path)), [external.path, newAsset.path])
    }
    func testDuplicateOBBNamesStayUnmappedEvenAfterTargetReview() throws {
        let (root, input, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for directory in ["A", "B"] { try file("\(directory)/main.47.\(package).obb", in: input, text: directory) }
        let store = LocalProvisionalRecipeStore(root: root.appendingPathComponent("provisional"))
        let record = try LocalGameImport().createProvisionalAnalysis(from: input, store: store)
        let reviewed = try store.setExperimentalTarget(appID: "123456", provenance: "synthetic test", for: record.id)
        XCTAssertEqual(reviewed.externalFiles.count, 2)
        XCTAssertTrue(reviewed.externalFiles.allSatisfy { $0.destination == nil && $0.kind == nil })
        XCTAssertNil(reviewed.experimentalRecipe)
        XCTAssertEqual(reviewed.experimentalTarget?.toolchain, "850-cc2856c")
    }
    func testMultipleAPKsNeverChooseOneOrSavePartialRecord() throws {
        let (root, input, apk) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: apk, to: input.appendingPathComponent("another.apk"))
        let store = LocalProvisionalRecipeStore(root: root.appendingPathComponent("provisional"))
        XCTAssertThrowsError(try LocalGameImport().createProvisionalAnalysis(from: input, store: store))
        XCTAssertTrue(try store.loadAll().isEmpty)
    }
    func testIndividualAPKDoesNotAssociateUnselectedSiblingFiles() throws {
        let (root, input, apk) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try file("unrelated.pak", in: input)
        let store = LocalProvisionalRecipeStore(root: root.appendingPathComponent("provisional"))
        let record = try LocalGameImport().createProvisionalAnalysis(from: apk, store: store)
        XCTAssertTrue(record.externalFiles.isEmpty)
    }
    func testFolderWithRecipeUsesExistingDiscoveryAndDoesNotCreateProvisionalRecord() throws {
        let (root, input, apk) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let main = try file("main.47.\(package).obb", in: input)
        let extra = try file("extra.pak", in: input)
        let known = recipe(apk: apk), importer = LocalGameImport()
        let variants = LocalAPKVariantStore(root: root.appendingPathComponent("variants"))
        let selection = try importer.identify(input, recipes: [known], learning: LocalAPKLearningStore(variants: variants))
        let found = try importer.discover(in: input, recipe: selection.recipe, selectedAPK: selection.apk)
        XCTAssertTrue(found.canInstall)
        XCTAssertEqual(found.files[main.lastPathComponent]?.resolvingSymlinksInPath().standardizedFileURL.path, main.resolvingSymlinksInPath().standardizedFileURL.path)
        XCTAssertEqual(found.unmatchedFiles.map { $0.resolvingSymlinksInPath().standardizedFileURL.path }, [extra.resolvingSymlinksInPath().standardizedFileURL.path])
        let destinations = importer.automaticAdditionalDestinations(for: found, recipe: known)
        XCTAssertFalse(destinations.isEmpty)
        let variant = try importer.register(found, recipe: known, store: variants,
            additionalDestinations: destinations, automaticAdditionalPaths: Set(destinations.keys))
        XCTAssertEqual(variant.assets?.count, 2)
        let store = LocalProvisionalRecipeStore(root: root.appendingPathComponent("provisional"))
        XCTAssertThrowsError(try importer.createProvisionalAnalysis(from: input, knownRecipes: [known], store: store))
        XCTAssertTrue(try store.loadAll().isEmpty)
    }
}
