import XCTest
@testable import AVPPlayCore

final class AppIsolationTests: XCTestCase {
    func testModifiedIdentityHasSeparatePersistentRootsAndKeychainNamespaces() {
        let original = DataLocation.originalBundleIdentifier
        let modified = DataLocation.modifiedBundleIdentifier
        XCTAssertNotEqual(original, modified)
        XCTAssertFalse(DataLocation.isModified(bundleIdentifier: original))
        XCTAssertTrue(DataLocation.isModified(bundleIdentifier: modified))
        XCTAssertEqual(DataLocation.folderName(bundleIdentifier: original), "AVPPlay")
        XCTAssertEqual(DataLocation.folderName(bundleIdentifier: modified), "AVPPlayModificado")
        let supportRoot = FileManager.default.temporaryDirectory.appendingPathComponent("avpplay-support-\(UUID())")
        let outsideOverride = FileManager.default.temporaryDirectory.appendingPathComponent("avpplay-home-\(UUID())").path
        XCTAssertEqual(DataLocation.resolvedBase(bundleIdentifier: original, support: supportRoot, homeOverride: outsideOverride).path, outsideOverride)
        XCTAssertEqual(DataLocation.resolvedBase(bundleIdentifier: modified, support: supportRoot,
                                                 homeOverride: "/Users/test/Library/Application Support/AVPPlay").lastPathComponent,
                       "AVPPlayModificado")
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("avpplay-isolation-roots-\(UUID())")
        let originalBase = DataLocation.defaultBase(bundleIdentifier: original, support: support)
        let modifiedBase = DataLocation.defaultBase(bundleIdentifier: modified, support: support)
        XCTAssertNotEqual(originalBase, modifiedBase)
        try! FileManager.default.createDirectory(at: originalBase, withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: modifiedBase, withIntermediateDirectories: true)
        try! Data("original".utf8).write(to: originalBase.appendingPathComponent("probe.txt"))
        try! Data("modified".utf8).write(to: modifiedBase.appendingPathComponent("probe.txt"))
        XCTAssertEqual(try! String(contentsOf: originalBase.appendingPathComponent("probe.txt"), encoding: .utf8), "original")
        XCTAssertEqual(try! String(contentsOf: modifiedBase.appendingPathComponent("probe.txt"), encoding: .utf8), "modified")
        try? FileManager.default.removeItem(at: support)
        XCTAssertEqual(TokenStore.service(bundleIdentifier: original), "avpplay-meta")
        XCTAssertEqual(TokenStore.service(bundleIdentifier: modified), "avpplay-meta-modified")
        XCTAssertTrue(TokenStore.mayAdoptLegacy(bundleIdentifier: original))
        XCTAssertFalse(TokenStore.mayAdoptLegacy(bundleIdentifier: modified))
        XCTAssertEqual(GameServerStore.keychainService(bundleIdentifier: original), "avpplay-server")
        XCTAssertEqual(GameServerStore.keychainService(bundleIdentifier: modified), "avpplay-server-modified")
        XCTAssertNotEqual(StoreLocation.folderName(bundleIdentifier: original), StoreLocation.folderName(bundleIdentifier: modified))
        XCTAssertNotEqual(BackgroundService.label(bundleIdentifier: original), BackgroundService.label(bundleIdentifier: modified))
        XCTAssertTrue(BackgroundService.isEnabled(bundleIdentifier: original))
        XCTAssertFalse(BackgroundService.isEnabled(bundleIdentifier: modified))
        XCTAssertTrue(Updater.isEnabled(bundleIdentifier: original))
        XCTAssertFalse(Updater.isEnabled(bundleIdentifier: modified))
    }

    func testModifiedPersistentOverridesCannotAliasOfficialDataRoot() {
        let official = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AVPPlay", isDirectory: true)
        let modified = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AVPPlayModificado", isDirectory: true)
        let external = FileManager.default.temporaryDirectory.appendingPathComponent("avpplay-isolated-\(UUID())")

        XCTAssertFalse(DataLocation.isIsolated(official, bundleIdentifier: DataLocation.modifiedBundleIdentifier))
        XCTAssertFalse(DataLocation.isIsolated(official.appendingPathComponent("toolchains"), bundleIdentifier: DataLocation.modifiedBundleIdentifier))
        XCTAssertTrue(DataLocation.isIsolated(modified, bundleIdentifier: DataLocation.modifiedBundleIdentifier))
        XCTAssertTrue(DataLocation.isIsolated(external, bundleIdentifier: DataLocation.modifiedBundleIdentifier))
        XCTAssertTrue(DataLocation.isIsolated(official, bundleIdentifier: DataLocation.originalBundleIdentifier))
        XCTAssertEqual(AppIcon.steamCacheRoots(bundleIdentifier: DataLocation.modifiedBundleIdentifier, support: official), [])
        XCTAssertEqual(AppIcon.steamCacheRoots(bundleIdentifier: DataLocation.originalBundleIdentifier, support: official).count, 1)
    }

    func testLocalLibraryPreferenceMigrationCopiesOnlyLocalLibraryKeysOnce() {
        let suffix = UUID().uuidString
        let source = UserDefaults(suiteName: "avpplay-isolation-source-\(suffix)")!
        let target = UserDefaults(suiteName: "avpplay-isolation-target-\(suffix)")!
        defer {
            source.removePersistentDomain(forName: "avpplay-isolation-source-\(suffix)")
            target.removePersistentDomain(forName: "avpplay-isolation-target-\(suffix)")
        }
        let filters = Data("local filter fixture".utf8)
        let modes = Data("filter modes fixture".utf8)
        source.set(filters, forKey: "localRecipeFilters")
        source.set(modes, forKey: "localRecipeFilterModes")
        source.set("store-123", forKey: "localRecipeID")
        source.set("meta-account-fixture", forKey: "metaAccount")

        DataLocation.migrateLocalLibraryPreferencesIfNeeded(target: target, source: source, modified: true)

        XCTAssertEqual(target.data(forKey: "localRecipeFilters"), filters)
        XCTAssertEqual(target.data(forKey: "localRecipeFilterModes"), modes)
        XCTAssertEqual(target.string(forKey: "localRecipeID"), "store-123")
        XCTAssertNil(target.object(forKey: "metaAccount"))
        source.set(Data("changed after migration".utf8), forKey: "localRecipeFilters")
        DataLocation.migrateLocalLibraryPreferencesIfNeeded(target: target, source: source, modified: true)
        XCTAssertEqual(target.data(forKey: "localRecipeFilters"), filters)
    }
}

final class CandidateIsolationTests: XCTestCase {
    let candidate = DataLocation.candidateBundleIdentifier

    func testCandidateIdentityAnd179Compatibility() {
        let support = URL(fileURLWithPath: "/synthetic/support")
        XCTAssertEqual(DataLocation.defaultBase(bundleIdentifier: candidate, support: support).path,
                       "/synthetic/support/AVPPlayCandidate187")
        XCTAssertEqual(DataLocation.resolvedBase(bundleIdentifier: DataLocation.modifiedBundleIdentifier,
                        support: support, homeOverride: "/synthetic/override").path,
                       "/synthetic/support/AVPPlayModificado")
        XCTAssertTrue(DataLocation.isModified(bundleIdentifier: candidate))
        XCTAssertFalse(TokenStore.mayAdoptLegacy(bundleIdentifier: candidate))
        XCTAssertNotEqual(TokenStore.service(bundleIdentifier: candidate), TokenStore.service(bundleIdentifier: DataLocation.modifiedBundleIdentifier))
        XCTAssertNotEqual(GameServerStore.keychainService(bundleIdentifier: candidate), GameServerStore.keychainService(bundleIdentifier: DataLocation.modifiedBundleIdentifier))
        XCTAssertFalse(BackgroundService.isEnabled(bundleIdentifier: candidate))
        XCTAssertFalse(Updater.isEnabled(bundleIdentifier: candidate))
    }

    func testCandidateOverrideRejectsInstalledRootsAncestorsDescendantsAndSymlinks() throws {
        let support = DataLocation.applicationSupport
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        for name in ["AVPPlay", "AVPPlayModificado", "AVPPlayCandidate", "QuestInstaller"] {
            let protected = support.appendingPathComponent(name)
            for url in [protected, protected.appendingPathComponent("jobs"), support] {
                XCTAssertFalse(DataLocation.isIsolated(url, bundleIdentifier: candidate))
                XCTAssertNil(DataLocation.directoryOverride(url.path, bundleIdentifier: candidate))
                XCTAssertEqual(DataLocation.resolvedBase(bundleIdentifier: candidate, support: support,
                                homeOverride: url.path), DataLocation.defaultBase(bundleIdentifier: candidate, support: support))
            }
            let alias = scratch.appendingPathComponent(name)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: protected)
            XCTAssertFalse(DataLocation.isIsolated(alias.appendingPathComponent("jobs"), bundleIdentifier: candidate))
        }
        XCTAssertEqual(DataLocation.resolvedBase(bundleIdentifier: candidate, support: support, homeOverride: scratch.path).path, scratch.path)
        XCTAssertEqual(DataLocation.resolvedBase(bundleIdentifier: candidate, support: support, homeOverride: "relative"),
                       DataLocation.defaultBase(bundleIdentifier: candidate, support: support))
    }

    func testCandidateNeverMigratesPreferences() {
        let sourceName = "candidate-source-\(UUID())", targetName = "candidate-target-\(UUID())"
        let source = UserDefaults(suiteName: sourceName)!, target = UserDefaults(suiteName: targetName)!
        defer { source.removePersistentDomain(forName: sourceName); target.removePersistentDomain(forName: targetName) }
        source.set("old-game", forKey: "localRecipeID")
        DataLocation.migrateLocalLibraryPreferencesIfNeeded(target: target, source: source, modified: true, bundleIdentifier: candidate)
        XCTAssertNil(target.object(forKey: "localRecipeID"))
        XCTAssertNil(target.object(forKey: "avpplayModifiedLocalLibraryPreferencesMigrated"))
    }

    // This test is launched with the same bootstrap as the future packaged GUI/CLI.
    // No toolchain, APK, game build or device is used.
    func testBootstrappedStageResumeDefaultPaths() throws {
        guard ProcessInfo.processInfo.environment["AVPPLAY_ISOLATION_TEST"] == "1" else {
            throw XCTSkip("Run via candidate-launcher.sh with an isolated AVPPLAY_HOME")
        }
        let root = DataLocation.base.resolvingSymlinksInPath()
        XCTAssertEqual(JobStore.defaultDirectory.resolvingSymlinksInPath(), root.appendingPathComponent("jobs", isDirectory: true))
        XCTAssertEqual(LocalAPKVariantStore().root.resolvingSymlinksInPath(), root.appendingPathComponent("local-variants", isDirectory: true))
        XCTAssertEqual(CoverCache.defaultDirectory.resolvingSymlinksInPath(), root.appendingPathComponent("cache/covers", isDirectory: true))
        XCTAssertTrue(DataLocation.temporaryDirectory.resolvingSymlinksInPath().path.hasPrefix(root.path + "/tmp"))
        XCTAssertEqual(DataLocation.resolvedTemporaryDirectory(bundleIdentifier: candidate, base: root,
                        system: URL(fileURLWithPath: "/system/tmp")).path, root.appendingPathComponent("tmp").path)
        XCTAssertEqual(DataLocation.resolvedTemporaryDirectory(bundleIdentifier: DataLocation.modifiedBundleIdentifier,
                        base: root, system: URL(fileURLWithPath: "/system/tmp")).path, "/system/tmp")
        let stage = StageWorkspace.makeScratchURL().resolvingSymlinksInPath()
        XCTAssertEqual(stage.deletingLastPathComponent().path, DataLocation.temporaryDirectory.resolvingSymlinksInPath().path)
        XCTAssertTrue(stage.lastPathComponent.hasPrefix("avpplay-stage-toolchain-"))
        XCTAssertNotEqual(stage, StageWorkspace.makeScratchURL())
        let buildRoot = root.appendingPathComponent("build-only")
        XCTAssertFalse(DataLocation.isIsolated(DataLocation.applicationSupport.appendingPathComponent("AVPPlayModificado/build-only"), bundleIdentifier: candidate))
        XCTAssertTrue(DataLocation.isIsolated(buildRoot, bundleIdentifier: candidate))
        let jobs = JobStore.defaultDirectory
        try FileManager.default.createDirectory(at: jobs, withIntermediateDirectories: true)
        let receipt = jobs.appendingPathComponent("synthetic-resume-probe")
        try Data("synthetic".utf8).write(to: receipt)
        defer { try? FileManager.default.removeItem(at: receipt) }
        XCTAssertEqual(try Data(contentsOf: receipt), Data("synthetic".utf8))
    }
}
