import XCTest
@testable import AVPPlayCore

final class Selective180Tests: XCTestCase {
    func testBeatSaber1453IsAnExplicitGatedVariantWhile1452RemainsDefault() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let store = RecipeStore(directory: root.appendingPathComponent("recipes"))
        let primary = try XCTUnwrap(try store.loadAll().first { $0.id == "beatsaber140" })
        XCTAssertEqual(primary.versionCode, 3148)
        let variant = try XCTUnwrap(store.loadVariants().first { $0.id == primary.id && $0.versionCode == 3237 })
        XCTAssertEqual(variant.toolchain.minCommit, "a61188d")
        XCTAssertEqual(variant.package, primary.package)
        XCTAssertEqual(variant.toolchain.target, primary.toolchain.target)
        XCTAssertEqual(variant.status.playability, "untested")
    }

    func testLegacyManifestRetainsGlobalRevisionFallback() throws {
        let json = """
        {"format":1,"version":750,"commit":"900daf8","ancestors":["900daf8"],"created":"2026-01-01T00:00:00Z","appRevision":748}
        """
        let manifest = try ToolchainPackager.decoder.decode(ToolchainManifest.self, from: Data(json.utf8))
        XCTAssertEqual(manifest.revisions.forTarget("re4"), 748)
        XCTAssertEqual(manifest.revisions.forTarget("unknown"), 748)
    }

    func testAffectedGameThresholdDoesNotFlagOtherGames() throws {
        let json = """
        {"format":1,"version":824,"commit":"abcdef0","ancestors":["abcdef0"],"created":"2026-01-01T00:00:00Z","appRevision":824,"allRevision":750,"gameRevisions":{"beatsaber140":824,"re4":700}}
        """
        let manifest = try ToolchainPackager.decoder.decode(ToolchainManifest.self, from: Data(json.utf8))
        XCTAssertEqual(manifest.revisions.forTarget("beatsaber140"), 824)
        XCTAssertEqual(manifest.revisions.forTarget("re4"), 750)
        XCTAssertEqual(manifest.revisions.forTarget("batman"), 750)
    }

    func testSteamConfigTimeoutRetainsAcceptedLogin() {
        let output = "Using cached credentials\nWaiting for client config\nERROR Failed to load platform info"
        XCTAssertFalse(SteamRun.storedLoginRejected(output))
        if case .steamNotAnswering = SteamRun.failure(output) {} else { XCTFail("Must preserve accepted sign-in") }
    }

    func testSteamRejectedCachedLoginRequestsFreshSignIn() {
        let output = "Using cached credentials\nERROR Invalid Password"
        XCTAssertTrue(SteamRun.storedLoginRejected(output))
        if case .notSignedIn = SteamRun.failure(output) {} else { XCTFail("Must identify rejected sign-in") }
        XCTAssertFalse(SteamRun.storedLoginRejected("Network unavailable"))
    }

    func testInstalled824MetadataCannotClaimOnlyBeatSaberAffected() throws {
        let json = """
        {"format":1,"version":824,"commit":"a61188d","ancestors":["a61188d"],"created":"2026-01-01T00:00:00Z","allRevision":824,"appRevision":824}
        """
        let manifest = try ToolchainPackager.decoder.decode(ToolchainManifest.self, from: Data(json.utf8))
        XCTAssertEqual(manifest.revisions.forTarget("batman"), 824)
    }
}
