import XCTest
@testable import AVPPlayCore

/// Exercises the same workspace owner used by Installer.stage. All container operations
/// below are in-memory simulations; no DeviceControl, game compiler or headset is used.
final class StageWorkspaceTests: XCTestCase {
    private enum SimulatedFailure: Error { case prepare, transfer, consumer }

    private final class Container {
        var files: [String: Data] = [:]
        var uploaded: [String] = []
        var failAsset = false

        var adapter: InstallationContent.Container {
            .init(stat: { path in
                guard let bytes = self.files[path] else { return nil }
                return RemoteFile(relativePath: (path as NSString).lastPathComponent,
                    size: Int64(bytes.count), isDirectory: false, modified: Date(timeIntervalSince1970: 200))
            }, fetch: { path, local in
                try XCTUnwrap(self.files[path]).write(to: local)
            }, put: { source, path in
                if self.failAsset && path.contains("/assets/") { throw SimulatedFailure.transfer }
                self.files[path] = try Data(contentsOf: source) // also proves source still exists
                self.uploaded.append(path)
            })
        }
    }

    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stage-lifetime-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func recipe(_ id: String) throws -> Recipe {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try RecipeStore(directory: root.appendingPathComponent("recipes")).load(id: id)
    }

    private func write(_ bytes: Data, to path: URL) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: path)
    }

    private func checkEntries(_ entries: [InstallationContent.Entry], target: String) {
        XCTAssertEqual(Set(entries.map(\.destination)), Set([
            "Documents/\(target)/AndroidManifest.xml", "Documents/\(target)/apktool.yml",
            "Documents/\(target)/assets/global_localize_PTBR_P.pak",
            "Documents/\(target)/assets/nested/data.bin"
        ]))
    }

    func testFreshStageKeepsPreparedMetadataAndAllAssetsUntilVerificationThenCleansUp() throws {
        let root = try scratch(), source = try Verified850Fixture.source()
        var recipe = try recipe("batman")
        recipe.files = recipe.files.filter { $0.role == "apk" }; recipe.trees = nil; recipe.assetFiles = nil
        let apk = try LocalAPKVariantTests().makeAPK(in: root)
        let contents = root.appendingPathComponent("synthetic-apk")
        try write(Data("synthetic PTBR".utf8), to: contents.appendingPathComponent("assets/global_localize_PTBR_P.pak"))
        try write(Data("synthetic nested".utf8), to: contents.appendingPathComponent("assets/nested/data.bin"))
        let zip = Process(); zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-q", "-r", apk.path, "assets"]; zip.currentDirectoryURL = contents
        try zip.run(); zip.waitUntilExit(); XCTAssertEqual(zip.terminationStatus, 0)
        let variants = LocalAPKVariantStore(root: root.appendingPathComponent("variants"))
        let variant = try variants.register(from: apk, recipe: recipe)
        let store = ContentStore(root: root.appendingPathComponent("store"))
        var prepares = 0
        let workspace = try StageWorkspace(source: source, preservedBuild: nil) { copy in
            prepares += 1
            XCTAssertTrue(FileManager.default.fileExists(atPath: copy.root.path))
            try copy.prepare(recipe: KleptonRecipeCompatibility.resolve(recipe), store: store,
                localAPKVariantID: variant.id, localVariants: variants, verifyLocalAssetHashes: false)
        }
        defer { workspace.cleanup() }
        let staging = workspace.toolchain.root
        XCTAssertEqual(prepares, 1)
        XCTAssertNotEqual(staging, source.root)
        let entries = try InstallationContent.prepared(toolchain: workspace.toolchain, recipe: recipe,
            metadataWorkspace: staging)
        checkEntries(entries, target: recipe.toolchain.target)
        let container = Container()
        try InstallationContent.sync(entries, container: container.adapter, receipts: root.appendingPathComponent("receipt.json"))
        XCTAssertEqual(Set(container.uploaded), Set(entries.map(\.destination)))
        for entry in entries { XCTAssertEqual(container.files[entry.destination], try Data(contentsOf: entry.source)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path), "The last verifier still owns live sources")
        workspace.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.root.appendingPathComponent("batman/.qi-prepared").path))
        try RuntimePolicy177.requireSource(source)
    }

    func testBuildOnlyStageAndResumeReuseMetadataAndAssetsWithoutPrepareOrDeletingBuild() throws {
        let root = try scratch(), recipe = try recipe("store-3240283705987790")
        let build = try Verified850Fixture.build(root: root, recipe: recipe)
        let target = KleptonRecipeCompatibility.resolve(recipe).toolchain.target
        let tree = build.workspace.root.appendingPathComponent(target)
        try write(Data("synthetic PTBR".utf8), to: tree.appendingPathComponent("assets/global_localize_PTBR_P.pak"))
        try write(Data("synthetic nested".utf8), to: tree.appendingPathComponent("assets/nested/data.bin"))
        let before = try InstallationContent.prepared(toolchain: build.workspace, recipe: recipe)
        let container = Container(), receipt = root.appendingPathComponent("receipt.json")
        container.failAsset = true
        do {
            let workspace = try StageWorkspace(source: build.runtime, preservedBuild: build.artifact) { _ in
                XCTFail("A valid Build Only must never repeat Prepare")
            }
            defer { workspace.cleanup() }
            XCTAssertEqual(workspace.toolchain.root, build.workspace.root)
            let entries = try InstallationContent.prepared(toolchain: workspace.toolchain, recipe: recipe,
                metadataWorkspace: workspace.toolchain.root)
            checkEntries(entries, target: target)
            XCTAssertEqual(entries, before)
            XCTAssertThrowsError(try InstallationContent.sync(entries, container: container.adapter, receipts: receipt)) {
                XCTAssertTrue($0 is SimulatedFailure)
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: build.workspace.root.path))
        let copiedBeforeResume = container.uploaded
        XCTAssertEqual(copiedBeforeResume.count, 2, "Only the two metadata files were copied before the simulated failure")
        container.failAsset = false
        do {
            let workspace = try StageWorkspace(source: build.runtime, preservedBuild: build.artifact) { _ in
                XCTFail("Resume must not repeat Prepare or Build")
            }
            defer { workspace.cleanup() }
            let entries = try InstallationContent.prepared(toolchain: workspace.toolchain, recipe: recipe,
                metadataWorkspace: workspace.toolchain.root)
            try InstallationContent.sync(entries, container: container.adapter, receipts: receipt)
            for entry in entries { XCTAssertEqual(container.files[entry.destination], try Data(contentsOf: entry.source)) }
        }
        XCTAssertEqual(container.uploaded.count, 4, "Resume uploads only the two pending assets")
        XCTAssertEqual(Array(container.uploaded.prefix(2)), copiedBeforeResume)
        XCTAssertEqual(try InstallationContent.prepared(toolchain: build.workspace, recipe: recipe), before)
        try build.artifact.verifyCopy(build.app)
        try RuntimePolicy177.requireSource(build.runtime)
    }

    func testPrepareFailureRemovesScratchAndPreservesSharedToolchain() throws {
        let source = try Verified850Fixture.source()
        var created: URL?
        XCTAssertThrowsError(try StageWorkspace(source: source, preservedBuild: nil) { copy in
            created = copy.root
            XCTAssertTrue(FileManager.default.fileExists(atPath: copy.root.path))
            throw SimulatedFailure.prepare
        }) { XCTAssertTrue($0 is SimulatedFailure) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(created).path))
        try RuntimePolicy177.requireSource(source)
    }

    func testConsumerFailureCleansScratchAfterLastConsumer() throws {
        let source = try Verified850Fixture.source()
        var created: URL?
        func consume() throws {
            let workspace = try StageWorkspace(source: source, preservedBuild: nil) { _ in }
            defer { workspace.cleanup() }
            created = workspace.toolchain.root
            XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.toolchain.root.path))
            throw SimulatedFailure.consumer
        }
        XCTAssertThrowsError(try consume()) { XCTAssertTrue($0 is SimulatedFailure) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(created).path))
        try RuntimePolicy177.requireSource(source)
    }
}
