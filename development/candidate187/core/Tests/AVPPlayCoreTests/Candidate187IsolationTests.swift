import XCTest
@testable import AVPPlayCore

final class Candidate187IsolationTests: XCTestCase {
    func testExclusiveIdentityAndNamespaces() {
        let id = DataLocation.candidateBundleIdentifier
        XCTAssertEqual(id, "io.github.mymartek.avpplay.modified.candidate187")
        XCTAssertEqual(DataLocation.folderName(bundleIdentifier: id), "AVPPlayCandidate187")
        XCTAssertEqual(DataLocation.preferencesDomain(bundleIdentifier: id), id + ".preferences")
        XCTAssertNotEqual(DataLocation.preferencesDomain(bundleIdentifier: id), id)
        XCTAssertNil(DataLocation.preferencesDomain(bundleIdentifier: "io.github.mymartek.avpplay.modified.candidate186"))
        XCTAssertNil(DataLocation.preferencesDomain(bundleIdentifier: "io.github.mymartek.avpplay.modified.candidate"))
        XCTAssertNil(DataLocation.preferencesDomain(bundleIdentifier: DataLocation.originalBundleIdentifier))
        XCTAssertEqual(TokenStore.service(bundleIdentifier: id), "avpplay-meta-candidate187")
        XCTAssertEqual(GameServerStore.keychainService(bundleIdentifier: id), "avpplay-server-candidate187")
        XCTAssertEqual(StoreLocation.folderName(bundleIdentifier: id), "AVP Play Candidate 187 Downloads")
        XCTAssertFalse(BackgroundService.isEnabled(bundleIdentifier: id))
        XCTAssertEqual(BackgroundService.label(bundleIdentifier: id), id + ".renew")
        XCTAssertFalse(Updater.isEnabled(bundleIdentifier: id))
        XCTAssertEqual(RemoteWire.serviceType, "_avpplay-c187._tcp")
        XCTAssertEqual(RemoteWire.defaultPort, 47988)
        XCTAssertEqual(RemoteWire.pairPort, 47989)
        XCTAssertEqual(IsolatedRemoteBuild.bundleID, id + ".remote")
    }

    func testProtectedApplicationsCannotBecomeWritableRoots() {
        for path in ["Applications/AVP Play Candidate 185.app", "Applications/AVP Play Candidate 186.app", "Applications/AVP Play Modificado"] {
            let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(path)
            XCTAssertFalse(DataLocation.isIsolated(root.appendingPathComponent("data"),
                bundleIdentifier: DataLocation.candidateBundleIdentifier))
        }
    }

    func testCandidate186DataRootsAndAliasesAreRejectedWithoutMigration() throws {
        let id = DataLocation.candidateBundleIdentifier
        let support = DataLocation.applicationSupport
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("isolation187-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        for name in ["AVPPlayCandidate185", "AVPPlayCandidate186"] {
            let old = support.appendingPathComponent(name)
            let alias = scratch.appendingPathComponent(name)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: old)
            for path in [old, old.appendingPathComponent("jobs"), alias, alias.appendingPathComponent("build-only")] {
                XCTAssertFalse(DataLocation.isIsolated(path, bundleIdentifier: id))
                XCTAssertNil(DataLocation.directoryOverride(path.path, bundleIdentifier: id))
                XCTAssertEqual(DataLocation.resolvedBase(bundleIdentifier: id, support: support, homeOverride: path.path).path,
                    support.appendingPathComponent("AVPPlayCandidate187").path)
            }
        }
    }

    func testCandidatePreferencesStayEmptyAndNeverAdoptOlderDomains() throws {
        // Synthetic domains only; no preferences from an installed app are read or written.
        let token = UUID().uuidString
        let oldName = "test.c186." + token, newName = "test.c187." + token
        let old = try XCTUnwrap(UserDefaults(suiteName: oldName))
        let fresh = try XCTUnwrap(UserDefaults(suiteName: newName))
        defer { old.removePersistentDomain(forName: oldName); fresh.removePersistentDomain(forName: newName) }
        old.set("never import", forKey: "localRecipeID")
        old.set("never import account", forKey: "metaAccount")
        DataLocation.migrateLocalLibraryPreferencesIfNeeded(target: fresh, source: old,
            modified: true, bundleIdentifier: DataLocation.candidateBundleIdentifier)
        XCTAssertNil(fresh.object(forKey: "localRecipeID"))
        XCTAssertNil(fresh.object(forKey: "metaAccount"))
        XCTAssertTrue((fresh.persistentDomain(forName: newName) ?? [:]).isEmpty)
        XCTAssertNotEqual(DataLocation.candidateBundleIdentifier, "io.github.mymartek.avpplay.modified.candidate186")
    }

    func testRemoteAdaptationOnlyChangesDisposableSource() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let protocolFile = root.appendingPathComponent("Sources/Shared/RemoteProtocol.swift")
        let support = root.appendingPathComponent("Sources/Model/Support.swift")
        let info = root.appendingPathComponent("Sources/Info.plist")
        for file in [protocolFile, support, info] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try "_avpplay-iso._tcp 47821 47822 avpplay-isolated-remote-pair-v1".write(to: protocolFile, atomically: true, encoding: .utf8)
        try "io.github.mymartek.avpplay.modified.remote".write(to: support, atomically: true, encoding: .utf8)
        try "_avpplay-iso._tcp".write(to: info, atomically: true, encoding: .utf8)
        try IsolatedRemoteBuild.isolateSource(root)
        let text = try String(contentsOf: protocolFile)
        XCTAssertTrue(text.contains(RemoteWire.serviceType))
        XCTAssertTrue(text.contains("47988 47989"))
        XCTAssertFalse(text.contains("47821"))
        XCTAssertEqual(try String(contentsOf: support), IsolatedRemoteBuild.bundleID)
        XCTAssertEqual(try String(contentsOf: info), RemoteWire.serviceType)
        XCTAssertThrowsError(try IsolatedRemoteBuild.isolateSource(root), "Unexpected/already adapted input must fail closed")
    }
}
