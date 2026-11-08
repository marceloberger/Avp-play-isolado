import XCTest
import CryptoKit
@testable import AVPPlayCore

final class AppleSigningInventoryTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let certificate = Data("fixture certificate fingerprint only".utf8)
    var identity: String { Insecure.SHA1.hash(data: certificate).map { String(format: "%02X", $0) }.joined() }
    var values: [String: Any] { [
        "UUID": "fixture", "CreationDate": now.addingTimeInterval(-100),
        "ExpirationDate": now.addingTimeInterval(100), "Platform": ["xrOS"],
        "ProvisionedDevices": ["headset"], "DeveloperCertificates": [certificate],
        "Entitlements": ["application-identifier": "TEAM.bundle",
                         "com.apple.developer.kernel.extended-virtual-addressing": true,
                         "com.apple.developer.low-latency-streaming": true]
    ] }

    func testCurrentProfileRequiresMatchingLocalIdentityAndReportsCapabilities() throws {
        let p = try AppleSigningInventory.describe(values, identities: [identity], device: "headset", now: now)
        XCTAssertTrue(p.problems.isEmpty)
        XCTAssertTrue(p.extendedAddressing)
        XCTAssertTrue(p.lowLatency)
        XCTAssertEqual(p.applicationIdentifier, "TEAM.bundle")
        let missing = try AppleSigningInventory.describe(values, identities: [], device: "headset", now: now)
        XCTAssertEqual(missing.problems.count, 1)
    }

    func testExpiredWrongPlatformAndWrongDeviceAreReported() throws {
        var v = values
        v["ExpirationDate"] = now
        v["Platform"] = ["iOS"]
        let p = try AppleSigningInventory.describe(v, identities: [identity], device: "other", now: now)
        XCTAssertEqual(p.problems.count, 3)
    }

    func testFutureProfileAndMissingStructureAreNotAcceptedAsCurrent() throws {
        var v = values
        v["CreationDate"] = now.addingTimeInterval(1)
        XCTAssertEqual(try AppleSigningInventory.describe(v, identities: [identity], device: nil, now: now).problems.count, 1)
        v.removeValue(forKey: "DeveloperCertificates")
        XCTAssertThrowsError(try AppleSigningInventory.describe(v, identities: [identity], device: nil, now: now))
    }

    func testInventoryDoesNotInventAbsentEntitlements() throws {
        var v = values
        v["Entitlements"] = ["application-identifier": "TEAM.bundle"]
        let p = try AppleSigningInventory.describe(v, identities: [identity], device: nil, now: now)
        XCTAssertFalse(p.extendedAddressing)
        XCTAssertFalse(p.lowLatency)
    }

    func testLiveReadOnlyInventory() throws {
        guard ProcessInfo.processInfo.environment["AVPPLAY_AUDIT_APPLE_INVENTORY"] == "1" else {
            throw XCTSkip("Explicit read-only audit opt-in required")
        }
        let snapshot = AppleSigningInventory.scan(team: "BB7G7A8FSP", device: "00008112-001259EC1184A01E")
        XCTAssertEqual(snapshot.teams.first { $0.id == "BB7G7A8FSP" }?.free, false)
        XCTAssertFalse(snapshot.identities.isEmpty)
        let deadpool = try XCTUnwrap(snapshot.profiles.first { $0.id == "8e7be0f9-fc45-429d-8f78-0c37ab9513b6" })
        XCTAssertTrue(deadpool.problems.isEmpty, deadpool.problems.joined(separator: "; "))
        XCTAssertTrue(deadpool.extendedAddressing)
        XCTAssertTrue(deadpool.lowLatency)
        print("Read-only inventory: \(snapshot.identities.count) identities; \(snapshot.profiles.count) authenticated team profiles; \(snapshot.errors.count) decode/read errors.")
        for profile in snapshot.profiles { print("\(profile.id): \(profile.applicationIdentifier); \(profile.problems)") }
        for error in snapshot.errors { print(error) }
    }
}
