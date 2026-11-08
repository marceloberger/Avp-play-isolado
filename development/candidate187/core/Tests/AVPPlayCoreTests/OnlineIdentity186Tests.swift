import XCTest
@testable import AVPPlayCore

final class OnlineIdentity186Tests: XCTestCase {
    private func game(_ package: String = "com.example.game", id: String = "123456789", status: String = "untested") -> CatalogGame {
        CatalogGame(appId: id, title: "Example", package: package, status: status, works: 0, problems: 0, fails: 0)
    }

    func testExactMatchAndAllPages() async throws {
        let wrong = game("com.example.game.demo")
        let exact = game()
        let result = try await AutomaticAPKIdentity.resolveWithOnlineFallback(package: exact.package, offline: []) { query, page in
            XCTAssertEqual(query, exact.package)
            return .init(games: page == 0 ? [wrong] : [exact], more: page == 0)
        }
        XCTAssertEqual(result?.appID, exact.appId)
        XCTAssertTrue(result?.isValid == true)
    }

    func testConflictOnLaterPageAndNonExactFailClosed() async throws {
        let a = game(), b = game(id: "987654321")
        let conflict = try await AutomaticAPKIdentity.resolveWithOnlineFallback(package: a.package, offline: []) { _, page in
            .init(games: page == 0 ? [a] : [b], more: page == 0)
        }
        XCTAssertNil(conflict)
        let missing = try await AutomaticAPKIdentity.resolveWithOnlineFallback(package: a.package, offline: []) { _, _ in
            .init(games: [self.game("COM.example.game"), self.game("com.example.game.demo")], more: false)
        }
        XCTAssertNil(missing)
    }

    func testOfflineWinsAndOfflineConflictNeverQueries() async throws {
        let a = AutomaticAPKIdentity(title: "Offline", package: "com.example.game", appID: "123456789", source: "https://avpplay.martek.de/api/v1/games/123456789")
        let b = AutomaticAPKIdentity(title: "Other", package: a.package, appID: "987654321", source: "https://avpplay.martek.de/api/v1/games/987654321")
        for entries in [[a], [a, b]] {
            let result = try await AutomaticAPKIdentity.resolveWithOnlineFallback(package: a.package, offline: entries) { _, _ in
                XCTFail("Offline evidence must prevent a request")
                throw CatalogError.unexpected
            }
            XCTAssertEqual(result, entries.count == 1 ? a : nil)
        }
    }

    func testIncompleteAndMalformedSearchFailClosed() async throws {
        let exact = game()
        let incomplete = try await AutomaticAPKIdentity.resolveWithOnlineFallback(package: exact.package, offline: []) { _, _ in
            .init(games: [exact], more: true)
        }
        XCTAssertNil(incomplete)
        let malformed = game(id: "invalid")
        let invalid = try await AutomaticAPKIdentity.resolveWithOnlineFallback(package: exact.package, offline: []) { _, _ in
            .init(games: [exact, malformed], more: false)
        }
        XCTAssertNil(invalid)
    }

    func testStorePersistsEvidenceWithoutActivatingAndRetainsManualDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let apk = try LocalAPKVariantTests().makeAPK(in: root, package: "com.example.game", nativeLibraries: ["libmain.so", "libunity.so"])
        let store = LocalProvisionalRecipeStore(root: root.appendingPathComponent("analysis"))
        let original = try store.create(from: apk)
        let draft = try store.saveExperimentalDraft(appID: "987654321", provenance: "manual review", runtime: .klepton850, for: original.id)
        let exact = game(status: "incompatible")
        let updated = try await store.resolveOnlineIdentity(for: original.id) { _, _ in
            .init(games: [exact], more: false)
        }
        XCTAssertEqual(updated.experimentalDraft185, draft.experimentalDraft185)
        XCTAssertEqual(updated.experimentalTarget, draft.experimentalTarget)
        XCTAssertNil(updated.experimentalRecipe)
        XCTAssertEqual(updated.automaticIdentity?.appID, exact.appId)
        XCTAssertFalse(updated.automaticTargetBlockers.isEmpty)
        XCTAssertEqual(try store.loadAll().first?.onlineIdentity186, updated.onlineIdentity186)
    }

    func testCancellationIsNotConvertedToSuccessfulAnalysis() async throws {
        do {
            _ = try await AutomaticAPKIdentity.resolveWithOnlineFallback(package: "com.example.game", offline: []) { _, _ in
                throw CancellationError()
            }
            XCTFail("Cancellation must propagate")
        } catch is CancellationError { }
    }

    func testNetworkFailureRetainsAnalysis() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let apk = try LocalAPKVariantTests().makeAPK(in: root, package: "com.example.game", nativeLibraries: ["libmain.so", "libunity.so"])
        let store = LocalProvisionalRecipeStore(root: root.appendingPathComponent("analysis"))
        let original = try store.create(from: apk)
        let saved = try XCTUnwrap(store.loadAll().first)
        let before = try Data(contentsOf: store.root.appendingPathComponent(original.id + ".json"))
        let updated = try await store.resolveOnlineIdentity(for: original.id) { _, _ in throw CatalogError.unreachable("test") }
        XCTAssertEqual(updated, saved)
        XCTAssertEqual(try Data(contentsOf: store.root.appendingPathComponent(original.id + ".json")), before)
    }
}
