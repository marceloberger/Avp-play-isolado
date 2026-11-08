import XCTest
import AVPPlayCore
@testable import AVPPlayApp

final class IsolatedRemoteCompanionTests: XCTestCase {
    func testDeviceStateDistinguishesUnknownMissingCurrentUpdateAndNoDowngrade() {
        let bundle = IsolatedRemoteBuild.bundleID
        XCTAssertEqual(IsolatedRemoteCompanionState.resolve(installedVersions: nil, bundleID: bundle, bundledVersion: "1.0.0"), .unknown)
        XCTAssertEqual(IsolatedRemoteCompanionState.resolve(installedVersions: [:], bundleID: bundle, bundledVersion: "1.0.0"), .notInstalled)
        XCTAssertEqual(IsolatedRemoteCompanionState.resolve(installedVersions: [bundle: "1.0.0"], bundleID: bundle, bundledVersion: "1.0.0"), .current(version: "1.0.0"))
        XCTAssertEqual(IsolatedRemoteCompanionState.resolve(installedVersions: [bundle: "0.9.0"], bundleID: bundle, bundledVersion: "1.0.0"), .updateAvailable(installed: "0.9.0"))
        XCTAssertEqual(IsolatedRemoteCompanionState.resolve(installedVersions: [bundle: "1.1.0"], bundleID: bundle, bundledVersion: "1.0.0"), .newerThanBundled(installed: "1.1.0"))
    }

    func testRemoteIdentityIsSeparateFromOfficialAndStateTextDoesNotClaimVisionProTesting() {
        XCTAssertEqual(IsolatedRemoteBuild.bundleID, "io.github.mymartek.avpplay.modified.candidate187.remote")
        XCTAssertNotEqual(IsolatedRemoteBuild.bundleID, "io.github.mymartek.avpplay.remote")
        XCTAssertTrue(IsolatedRemoteBuild.bundleID.hasSuffix(".candidate187.remote"))
        XCTAssertTrue(IsolatedRemoteCompanionState.notInstalled.description.contains("not installed"))
    }

    func testCompanionHasStableNavigationRoute() {
        XCTAssertEqual(IsolatedRemoteCompanion.route, "isolated-avp-play-remote")
        XCTAssertEqual(IsolatedRemoteCompanion.title, "AVP Play Remote")
        XCTAssertEqual(IsolatedRemoteNavigation.destination(for: IsolatedRemoteCompanion.route), .companionDetail)
        XCTAssertEqual(IsolatedRemoteNavigation.destination(for: "store-game-1"), .game("store-game-1"))
    }
}
