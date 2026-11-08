import XCTest
import CryptoKit
@testable import AVPPlayCore

final class ProvisioningProfileDecoderTests: XCTestCase {
    override func setUpWithError() throws {
        // The synthetic capability test needs no installed profile or Keychain access.
        if name.contains("testPersonalTeamProfileRequiresExactBundleAndKeepsRequiredCapabilities") { return }
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AVPPLAY_VALIDATE_PERSONAL_STATE"] == "1",
            "Installed profiles, identity and machine-specific assertions require explicit opt-in")
    }
    private let team = "BB7G7A8FSP"
    private let bundle = "marceloberger.bb7g7a8fsp.dev.klepton.target.x6072194326150034"
    private let device = "00008112-001259EC1184A01E"
    private let identity = "157B33F5F18FB5666BF391C62FDCE06879D9D2F5"

    private func installedProfiles() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["Library/Developer/Xcode/UserData/Provisioning Profiles", "Library/MobileDevice/Provisioning Profiles"]
            .map { home.appendingPathComponent($0).standardizedFileURL }
            .flatMap { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
            .filter { ["mobileprovision", "provisionprofile"].contains($0.pathExtension) }
    }

    func testNativeCMSDecoderAuthenticatesExistingXcodeProfiles() throws {
        let files = installedProfiles()
        guard !files.isEmpty else { throw XCTSkip("No local Xcode provisioning profiles are installed") }
        for file in files {
            let values = try ProvisioningProfileDecoder.decode(Data(contentsOf: file))
            XCTAssertEqual(values["UUID"] as? String, file.deletingPathExtension().lastPathComponent)
            XCTAssertNotNil(values["TeamIdentifier"] as? [String])
            XCTAssertNotNil(values["DeveloperCertificates"] as? [Data])
        }
    }

    func testNativeCMSDecoderRejectsTamperedProfileAndNonCMSBytes() throws {
        guard let file = installedProfiles().first else { throw XCTSkip("No local Xcode provisioning profiles are installed") }
        var tampered = try Data(contentsOf: file)
        tampered[tampered.count / 2] ^= 0x01
        XCTAssertThrowsError(try ProvisioningProfileDecoder.decode(tampered))
        XCTAssertThrowsError(try ProvisioningProfileDecoder.decode(Data("not a CMS profile".utf8)))
    }

    func testSignerLoadsVerifiedProfilesThroughNativeDecoder() throws {
        let profiles = ExistingAppSigner.profiles()
        guard !installedProfiles().isEmpty else { throw XCTSkip("No local Xcode provisioning profiles are installed") }
        XCTAssertFalse(profiles.isEmpty, "valid CMS-signed profiles must not disappear because security cms fails")
        XCTAssertTrue(profiles.allSatisfy { $0.values["UUID"] as? String == $0.path.deletingPathExtension().lastPathComponent })
        let first = try XCTUnwrap(profiles.first)
        XCTAssertNotNil(SigningProfiles.decode(first.path))
        XCTAssertEqual(SigningRecord.expiry(ofProfileAt: first.path), first.values["ExpirationDate"] as? Date)
    }

    func testCurrentAppleDevelopmentIdentityIsFoundByTeamOUAndValidIdentityHash() throws {
        let valid = SigningWarmUp.existingIdentities(team: team)
        XCTAssertTrue(valid.contains(identity), "must use the OU Team ID and only a security find-identity-valid certificate/private-key pair")
    }

    func testExistingTeamProfilesMatchCertificateAndDeviceButNotZeroCaliberBundle() throws {
        let profiles = ExistingAppSigner.profiles()
        guard !profiles.isEmpty else { throw XCTSkip("No local Xcode provisioning profiles are installed") }
        let active = profiles.filter { profile in
            guard (profile.values["TeamIdentifier"] as? [String])?.contains(team) == true,
                  (profile.values["Platform"] as? [String])?.contains(where: { ["xrOS", "visionOS", "XROS"].contains($0) }) == true,
                  (profile.values["ExpirationDate"] as? Date ?? .distantPast) > Date(),
                  (profile.values["ProvisionedDevices"] as? [String])?.contains(device) == true,
                  let certificates = profile.values["DeveloperCertificates"] as? [Data] else { return false }
            return certificates.contains { Insecure.SHA1.hash(data: $0).map { String(format: "%02X", $0) }.joined() == identity }
        }
        XCTAssertFalse(active.isEmpty)
        XCTAssertFalse(active.contains { profile in
            let prefix = (profile.values["ApplicationIdentifierPrefix"] as? [String])?.first ?? team
            let capabilities = profile.values["Entitlements"] as? [String: Any] ?? [:]
            return ExistingAppSigner.permits(capabilities["application-identifier"] ?? "", "\(prefix).\(bundle)")
        }, "existing profiles are valid but target other Bundle IDs")
    }

    func testPersonalTeamProfileRequiresExactBundleAndKeepsRequiredCapabilities() throws {
        let certificate = Data("fixture certificate".utf8)
        let fingerprint = Insecure.SHA1.hash(data: certificate).map { String(format: "%02X", $0) }.joined()
        let now = Date()
        let values: [String: Any] = [
            "UUID": "fixture-profile",
            "CreationDate": now.addingTimeInterval(-60),
            "ExpirationDate": now.addingTimeInterval(3600),
            "Platform": ["visionOS"],
            "TeamIdentifier": [team],
            "ApplicationIdentifierPrefix": [team],
            "ProvisionedDevices": [device],
            "DeveloperCertificates": [certificate],
            "Entitlements": [
                "application-identifier": "\(team).\(bundle)",
                "com.apple.developer.team-identifier": team,
                "get-task-allow": true,
                "keychain-access-groups": ["\(team).*"],
                "com.apple.developer.kernel.increased-memory-limit": true
            ]
        ]
        let profile = ExistingAppSigner.Profile(path: URL(fileURLWithPath: "/fixture/ZC2.mobileprovision"), data: Data(), values: values)
        let requested: [String: Any] = [
            "keychain-access-groups": ["$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)", "$(AppIdentifierPrefix)avpplay.shared"],
            "com.apple.developer.kernel.increased-memory-limit": true,
            "com.apple.developer.kernel.extended-virtual-addressing": true,
            "com.apple.developer.low-latency-streaming": true
        ]

        let plan = try ExistingAppSigner.plan(profiles: [profile], team: team, bundle: bundle,
            device: device, identity: fingerprint, requested: requested, free: true)
        let entitlements = try XCTUnwrap(PropertyListSerialization.propertyList(from: plan.entitlements, format: nil) as? [String: Any])
        XCTAssertEqual(entitlements["application-identifier"] as? String, "\(team).\(bundle)")
        XCTAssertNil(entitlements["com.apple.developer.kernel.extended-virtual-addressing"])
        XCTAssertNil(entitlements["com.apple.developer.low-latency-streaming"])
        XCTAssertEqual(entitlements["com.apple.developer.kernel.increased-memory-limit"] as? Bool, true)

        XCTAssertThrowsError(try ExistingAppSigner.plan(profiles: [profile], team: team, bundle: bundle + ".wrong",
            device: device, identity: fingerprint, requested: requested, free: true))
        XCTAssertThrowsError(try ExistingAppSigner.plan(profiles: [profile], team: team, bundle: bundle,
            device: device, identity: fingerprint, requested: requested, free: false))
        XCTAssertThrowsError(try ExistingAppSigner.plan(profiles: [], team: team, bundle: bundle,
            device: device, identity: fingerprint, requested: requested, free: true))
    }

    func testXcodeGeneratedZeroCaliberProfileIsAcceptedByBuild150SigningPlanner() throws {
        let profiles = ExistingAppSigner.profiles()
        let identities = SigningWarmUp.existingIdentities(team: team)
        XCTAssertTrue(identities.contains(identity))
        let profile = try XCTUnwrap(profiles.first { candidate in
            let values = candidate.values
            guard (values["TeamIdentifier"] as? [String])?.contains(team) == true,
                  let entitlements = values["Entitlements"] as? [String: Any],
                  let appID = entitlements["application-identifier"] else { return false }
            let prefix = (values["ApplicationIdentifierPrefix"] as? [String])?.first ?? team
            return ExistingAppSigner.permits(appID, "\(prefix).\(bundle)")
        }, "Xcode must leave a profile matching the exact Zero Caliber 2 Bundle ID")

        XCTAssertEqual(profile.values["UUID"] as? String, profile.path.deletingPathExtension().lastPathComponent)
        XCTAssertGreaterThan(try XCTUnwrap(profile.values["ExpirationDate"] as? Date), Date())
        XCTAssertTrue((profile.values["Platform"] as? [String] ?? []).contains { ["xrOS", "visionOS", "XROS"].contains($0) })
        XCTAssertTrue((profile.values["ProvisionedDevices"] as? [String] ?? []).contains(device))
        let certificates = try XCTUnwrap(profile.values["DeveloperCertificates"] as? [Data])
        XCTAssertTrue(certificates.contains { Insecure.SHA1.hash(data: $0).map { String(format: "%02X", $0) }.joined() == identity })

        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AVPPlayModificado")
        let entitlementsURL = support.appendingPathComponent(
            "build-only/x6072194326150034-ac6fecba-6a2b-43d5-8ae3-744b0c8b340e/visionos/Klepton.entitlements")
        let requested = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: entitlementsURL), format: nil) as? [String: Any])
        let plan = try ExistingAppSigner.select(profiles: [profile], identities: identities, team: team,
            bundle: bundle, device: device, requested: requested, free: AppleTeams.isFree(team)).plan
        let finalEntitlements = try XCTUnwrap(PropertyListSerialization.propertyList(from: plan.entitlements, format: nil) as? [String: Any])
        XCTAssertEqual(finalEntitlements["application-identifier"] as? String, "\(team).\(bundle)")
        XCTAssertEqual(finalEntitlements["com.apple.developer.team-identifier"] as? String, team)
        XCTAssertEqual(finalEntitlements["com.apple.developer.kernel.increased-memory-limit"] as? Bool, true)
        XCTAssertNil(finalEntitlements["com.apple.developer.kernel.extended-virtual-addressing"])
        XCTAssertNil(finalEntitlements["com.apple.developer.low-latency-streaming"])
        let expiry = try XCTUnwrap(profile.values["ExpirationDate"] as? Date)
        let formatter = ISO8601DateFormatter()
        print("Verified ZC2 provisioning profile: path=\(profile.path.path) uuid=\(profile.values["UUID"] as? String ?? "?") expires=\(formatter.string(from: expiry)) team=\(team) bundle=\(bundle) device=\(device) identity=\(identity) platform=\((profile.values["Platform"] as? [String] ?? []).joined(separator: ",")) entitlements=\(finalEntitlements.keys.sorted().joined(separator: ","))")
    }
}
