import XCTest
@testable import AVPPlayCore

final class LocalBundleIdentityTests: XCTestCase {
    let old = "marceloberger.dev.klepton.target.batman"
    let compiled = "marceloberger.bb7g7a8fsp.dev.klepton.target.batman"

    func testExplicitChoicePersistsInFrozenRequestAndRequiresReuse() throws {
        let choice = LocalBundleIdentity(destination: old, source: compiled)
        var request = InstallRequest(toolchain: "/fixture")
        XCTAssertThrowsError(try choice.apply(to: &request, target: "batman"))
        request.localAPKVariantID = "fixture"
        XCTAssertThrowsError(try choice.apply(to: &request, target: "batman"))
        request.reuseBuildOnly = true
        try choice.apply(to: &request, target: "batman")
        let frozen = try JSONDecoder().decode(InstallRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(frozen.bundleId, old); XCTAssertEqual(frozen.preservedBuildBundleID, compiled)
        XCTAssertEqual(frozen.reuseBuildOnly, true)
    }

    func testOtherGamesUnsafeIDsAndImplicitChangesAreRejected() throws {
        for id in ["marceloberger.dev.klepton.target.re4", " " + old, old + "\n", "../" + old, "", "prefix..target.batman"] {
            XCTAssertThrowsError(try LocalBundleIdentity(destination: id, source: compiled).validate(target: "batman"))
            XCTAssertThrowsError(try LocalBundleIdentity(destination: old, source: id).validate(target: "batman"))
        }
        let plain = try JSONDecoder().decode(InstallRequest.self, from: JSONEncoder().encode(InstallRequest(toolchain: "fixture")))
        XCTAssertNil(plain.preservedBuildBundleID); XCTAssertNil(plain.bundleId)
    }

    func fixture() throws -> (ReusableBuild, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("identity139-\(UUID())")
        let app = root.appendingPathComponent("Original.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": compiled, "CFBundleExecutable": "Fixture", "KLTree": "batman"], format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Info.plist"))
        try Data("compiled native bytes".utf8).write(to: app.appendingPathComponent("Fixture"))
        let artifact = ReusableBuild(app: app, workspace: root, sourceJobID: "fixture", bundleID: compiled, files: try ReusableBuild.inventory(app))
        return (artifact, root.appendingPathComponent("Copy.app"))
    }

    func testOnlyVerifiedCopyChangesAndExecutableStaysIdentical() throws {
        let (artifact, copy) = try fixture()
        try FileManager.default.copyItem(at: artifact.app, to: copy)
        try artifact.verifyCopy(copy)
        try ExistingAppSigner.adaptIdentity(of: copy, artifact: artifact, destination: old)
        XCTAssertEqual(try ReusableBuild.infoPlist(copy.appendingPathComponent("Info.plist"))["CFBundleIdentifier"] as? String, old)
        XCTAssertEqual(try ReusableBuild.inventory(artifact.app), artifact.files)
        XCTAssertEqual(try Hashing.sha256(of: copy.appendingPathComponent("Fixture")), artifact.files["Fixture"])
        XCTAssertThrowsError(try artifact.verifyCopy(copy), "The changed copy must never masquerade as the original artifact")
    }

    func testOriginalAliasAndNestedBundlesAreRefused() throws {
        let (artifact, copy) = try fixture()
        XCTAssertThrowsError(try ExistingAppSigner.adaptIdentity(of: artifact.app, artifact: artifact, destination: old))
        let alias = artifact.workspace.appendingPathComponent("Alias.app")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: artifact.app)
        XCTAssertThrowsError(try ExistingAppSigner.adaptIdentity(of: alias, artifact: artifact, destination: old))
        try FileManager.default.copyItem(at: artifact.app, to: copy)
        try FileManager.default.createDirectory(at: copy.appendingPathComponent("PlugIns/Other.appex"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try ExistingAppSigner.adaptIdentity(of: copy, artifact: artifact, destination: old))
        XCTAssertEqual(try ReusableBuild.inventory(artifact.app), artifact.files)
    }

    func testProfileForOriginalIsNotPermissionForNewIdentityOrDifferentPrefix() throws {
        let (fixture, cert) = ResumeReuseTests().profile()
        var profile = fixture
        profile.values["ApplicationIdentifierPrefix"] = ["OLDPREFIX1"]
        profile.values["Entitlements"] = ["application-identifier": "OLDPREFIX1." + old,
            "keychain-access-groups": ["OLDPREFIX1.*"], "get-task-allow": true]
        let requested = ["keychain-access-groups": ["$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)"]]
        let plan = try ExistingAppSigner.plan(profiles: [profile], team: "TEAM000001", bundle: old, device: "device", identity: cert, requested: requested, free: true)
        let entitlements = try XCTUnwrap(PropertyListSerialization.propertyList(from: plan.entitlements, format: nil) as? [String: Any])
        XCTAssertEqual(entitlements["application-identifier"] as? String, "OLDPREFIX1." + old)
        XCTAssertEqual(entitlements["keychain-access-groups"] as? [String], ["OLDPREFIX1." + old])
        XCTAssertThrowsError(try ExistingAppSigner.plan(profiles: [profile], team: "TEAM000001", bundle: compiled, device: "device", identity: cert, requested: requested, free: true))
        XCTAssertThrowsError(try ExistingAppSigner.plan(profiles: [profile], team: "TEAM000001", bundle: old, device: "device", identity: cert,
            requested: ["keychain-access-groups": ["TEAM000001." + old]], free: true))
    }
}
