import XCTest
@testable import AVPPlayCore

final class RuntimeFeature156Tests: XCTestCase {
    func testOldRequestsAndStampsRemainCompatible() throws {
        let fresh = InstallRequest(toolchain:"/fixture")
        let encoded = try JSONEncoder().encode(fresh)
        let decoded = try JSONDecoder().decode(InstallRequest.self,from: encoded)
        XCTAssertEqual(decoded.frameGeneration, .automatic)
        var legacyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacyJSON.removeValue(forKey: "frameGeneration")
        legacyJSON.removeValue(forKey: "coreMods")
        legacyJSON.removeValue(forKey: "surrealSupport")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyJSON)
        let legacy = try JSONDecoder().decode(InstallRequest.self, from: legacyData)
        XCTAssertNil(legacy.coreMods); XCTAssertNil(legacy.frameGeneration); XCTAssertNil(legacy.surrealSupport)
        XCTAssertFalse(try XCTUnwrap(AppStamp.parse("3148.750")).coreMods)
        let stamp = AppStamp.build(versionCode: 3237,toolchainVersion: 824,coreMods: true)
        XCTAssertTrue(try XCTUnwrap(AppStamp.parse(stamp)).coreMods)
        XCTAssertEqual(AppStamp.parse(stamp)?.toolchain,824)
    }

    func testRuntimeSettingsArePartOfArtifactReuseIdentity() {
        let automatic = InstallRequest(toolchain:"/fixture")
        XCTAssertEqual(automatic.frameGeneration, .automatic)
        var changed=automatic;changed.frameGeneration = .between
        XCTAssertFalse(ReusableBuild.sameOptions(automatic,changed))
        changed=automatic;changed.frameGeneration = .off
        XCTAssertFalse(ReusableBuild.sameOptions(automatic,changed))
        changed=automatic;changed.coreMods=true
        XCTAssertFalse(ReusableBuild.sameOptions(automatic,changed))
        changed=automatic;changed.surrealSDK = .bluetooth
        XCTAssertFalse(ReusableBuild.sameOptions(automatic,changed))
        changed=automatic;changed.controllerMode = .surreal
        XCTAssertFalse(ReusableBuild.sameOptions(automatic,changed))
        changed=automatic;changed.surrealSupport = false
        XCTAssertFalse(ReusableBuild.sameOptions(automatic,changed))
        var legacy = automatic; legacy.frameGeneration = nil
        changed=legacy; changed.frameGeneration = .off
        XCTAssertTrue(ReusableBuild.sameOptions(legacy,changed))
        changed=legacy; changed.frameGeneration = .automatic
        XCTAssertFalse(ReusableBuild.sameOptions(legacy,changed))

        var withAssets = automatic
        withAssets.localAssetsSHA256 = String(repeating: "a", count: 64)
        var changedAssets = withAssets
        changedAssets.localAssetsSHA256 = String(repeating: "b", count: 64)
        XCTAssertFalse(ReusableBuild.sameOptions(withAssets, changedAssets),
                       "Optional/additional asset changes must invalidate build reuse.")
        XCTAssertTrue(ReusableBuild.sameOptions(withAssets, withAssets))
    }

    func testBuildRecoveryPrefersRequestedRuntimeAndAssetSet() {
        var incompatible = InstallRequest(toolchain: "/fixture")
        incompatible.surrealSupport = true
        incompatible.localAssetsSHA256 = String(repeating: "a", count: 64)
        var requested = incompatible
        requested.surrealSupport = false
        requested.localAssetsSHA256 = String(repeating: "b", count: 64)
        XCTAssertFalse(LocalBuildRecovery.runtimeCompatible(incompatible, with: requested),
                       "An old runtime receipt cannot block a different requested runtime/assets set.")
        var compatible = requested
        compatible.controllerMode = .standard
        XCTAssertTrue(LocalBuildRecovery.runtimeCompatible(compatible, with: requested))
    }

    func testAutomaticReuseMatchesTargetDefaultAndPreservesLegacyOff() throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("avp-fg-reuse-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let targets = fixture.appendingPathComponent("visionos/targets.py")
        try FileManager.default.createDirectory(at: targets.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: fixture.appendingPathComponent("visionos/run.sh"))
        try Data("t.setdefault(\"framegen\", \"between\" if name == \"alyx\" else \"off\")\n".utf8).write(to: targets)
        let toolchain = try Toolchain(root: fixture)
        var request = InstallRequest(toolchain: fixture.path)
        XCTAssertTrue(ReusableBuild.matchesFrameGeneration(info: ["KLFrameGenDefault":"off"], request: request, target: "deadpool", toolchain: toolchain))
        XCTAssertTrue(ReusableBuild.matchesFrameGeneration(info: ["KLFrameGenDefault":"between"], request: request, target: "alyx", toolchain: toolchain))
        XCTAssertFalse(ReusableBuild.matchesFrameGeneration(info: ["KLFrameGenDefault":"between"], request: request, target: "deadpool", toolchain: toolchain))
        request.frameGeneration = .off
        XCTAssertTrue(ReusableBuild.matchesFrameGeneration(info: ["KLFrameGenDefault":"off"], request: request, target: "alyx", toolchain: toolchain))
        request.frameGeneration = nil
        XCTAssertTrue(ReusableBuild.matchesFrameGeneration(info: ["KLFrameGenDefault":"off"], request: request, target: "alyx", toolchain: toolchain))
        XCTAssertFalse(ReusableBuild.matchesFrameGeneration(info: ["KLFrameGenDefault":"between"], request: request, target: "alyx", toolchain: toolchain))
    }

    func testProductEvidencePreservesActualRuntimeDefaults() {
        let evidence=LocalAPKBuildEvidence(signedBuildSHA256:"a",unsignedBuildSHA256:"b",recipeSHA256:"c",
            settings:["Info.KLFrameGenDefault":"ahead","Info.KLScotland2CoreMods":"1","Info.KLSurrealAvailable":"NO"])
        let request=evidence.applyingProductDefaults(to:InstallRequest(toolchain:"/fixture"))
        XCTAssertEqual(request.frameGeneration,.ahead);XCTAssertEqual(request.coreMods,true);XCTAssertEqual(request.surrealSupport,false)
    }
}
