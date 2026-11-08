import XCTest
@testable import AVPPlayCore

final class ExperimentalInstallation168Tests: XCTestCase {
    private func temporary() throws -> URL {
        let p = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: p, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: p) }
        return p
    }
    func testEvidenceAllowsOnlyTheRegeneratedFrameworkAndCompleteDataInventory() throws {
        let spec = try ExperimentalInstallation168.specification()
        let changed = Set(spec.sourceAppFiles.keys).filter { spec.sourceAppFiles[$0] != spec.correctedAppFiles[$0] }
        XCTAssertEqual(changed, ["Frameworks/libqck.framework/libqck"])
        XCTAssertEqual(Set(spec.sourceAppFiles.keys), Set(spec.correctedAppFiles.keys))
        XCTAssertEqual(spec.dataFiles.count, 39)
        for path in spec.dataFiles.keys {
            XCTAssertEqual(try ExperimentalInstallation168.destination(for: path, target: spec.target), "Documents/" + path)
        }
    }
    func testDataDestinationsRefuseTraversalLibrariesAndOtherTargets() throws {
        for bad in ["../escape", "x123/../escape", "x123/lib/libmain.so", "x456.apk", "/tmp/game.apk"] {
            XCTAssertThrowsError(try ExperimentalInstallation168.destination(for: bad, target: "x123"))
        }
    }
    func testDataHashAndConfinementAreRequired() throws {
        let root = try temporary(), outside = try temporary()
        let data = Data("original assets".utf8), hash = Hashing.sha256(of: data)
        try data.write(to: root.appendingPathComponent("asset"))
        XCTAssertNoThrow(try ExperimentalInstallation168.confinedFile(root, relative: "asset", digest: hash))
        XCTAssertThrowsError(try ExperimentalInstallation168.confinedFile(root, relative: "asset", digest: String(repeating: "0", count: 64)))
        try data.write(to: outside.appendingPathComponent("external"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside.appendingPathComponent("external"))
        XCTAssertThrowsError(try ExperimentalInstallation168.confinedFile(root, relative: "link", digest: hash))
    }
    func testAnExistingBundleAlwaysBlocksReplacement() throws {
        let app = InstalledApp(bundleIdentifier: "example.laser", name: "Existing", version: "1", bundleVersion: "1")
        XCTAssertThrowsError(try ExperimentalInstallation168.requireNoReplacement([app], bundle: "example.laser"))
        XCTAssertNoThrow(try ExperimentalInstallation168.requireNoReplacement([], bundle: "example.laser"))
    }
    func testPhysicalDeviceRequirementsRemainMandatory() throws {
        for device in [Device(udid: "test", name: "Test", osVersion: "25.0", reachable: true, paired: true, developerMode: true),
                       Device(udid: "test", name: "Test", osVersion: "26.0", reachable: false, paired: true, developerMode: true),
                       Device(udid: "test", name: "Test", osVersion: "26.0", reachable: true, paired: true, developerMode: false)] {
            XCTAssertThrowsError(try ExperimentalInstallation168.requireDevice(device))
        }
    }
    func testAppManifestRejectsAnExtraOrChangedExecutable() throws {
        let app = try temporary()
        try Data("plist".utf8).write(to: app.appendingPathComponent("Info.plist"))
        try Data("native".utf8).write(to: app.appendingPathComponent("binary"))
        let expected = try ReusableBuild.inventory(app)
        XCTAssertNoThrow(try ExperimentalInstallation168.verifyApp(app, expected: expected))
        try Data("changed".utf8).write(to: app.appendingPathComponent("binary"))
        XCTAssertThrowsError(try ExperimentalInstallation168.verifyApp(app, expected: expected))
        try Data("native".utf8).write(to: app.appendingPathComponent("binary"))
        try Data().write(to: app.appendingPathComponent("extra"))
        XCTAssertThrowsError(try ExperimentalInstallation168.verifyApp(app, expected: expected))
    }
    func testOverlayOnlyChangesTheIsolatedSourceCopyAndRefusesASecondApplication() throws {
        let workspace = try temporary()
        let runtime = try Verified850Fixture.source()
        let (_, contract) = try RuntimePolicy177.contract()
        let paths = ["runtime/kl_x18.c", "runtime/kl_x18.h", "runtime/kl_image.c", "tools/klepton_ld.c"]
        for path in paths {
            let source = runtime.root.appendingPathComponent(path)
            let expected = try XCTUnwrap(contract.files.first { $0.path == path })
            XCTAssertEqual(try Hashing.sha256(of: source), expected.originalSHA256)
            let dest = workspace.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: dest)
        }
        let before = try paths.map { try Hashing.sha256(of: workspace.appendingPathComponent($0)) }
        try ExperimentalTLS170.apply(to: workspace)
        let after = try paths.map { try Hashing.sha256(of: workspace.appendingPathComponent($0)) }
        XCTAssertNotEqual(before, after)
        XCTAssertThrowsError(try ExperimentalTLS170.apply(to: workspace))
        XCTAssertEqual(after, try paths.map { try Hashing.sha256(of: workspace.appendingPathComponent($0)) })
        XCTAssertEqual(before, try paths.map { try Hashing.sha256(of: runtime.root.appendingPathComponent($0)) })
    }
    func testExperimentalProfileCannotDropMemoryOrLowLatencyCapabilities() throws {
        var (profile, identity) = ResumeReuseTests().profile()
        let required = ["com.apple.developer.kernel.increased-memory-limit": true,
                        "com.apple.developer.kernel.extended-virtual-addressing": true,
                        "com.apple.developer.low-latency-streaming": true]
        XCTAssertThrowsError(try ExistingAppSigner.plan(profiles: [profile], team: "TEAM000001", bundle: "test.game",
            device: "device", identity: identity, requested: required, free: false))
        var capabilities = try XCTUnwrap(profile.values["Entitlements"] as? [String: Any])
        for (key, value) in required { capabilities[key] = value }
        profile.values["Entitlements"] = capabilities
        let plan = try ExistingAppSigner.plan(profiles: [profile], team: "TEAM000001", bundle: "test.game",
            device: "device", identity: identity, requested: required, free: false)
        let actual = try XCTUnwrap(PropertyListSerialization.propertyList(from: plan.entitlements, format: nil) as? [String: Any])
        for key in required.keys { XCTAssertEqual(actual[key] as? Bool, true) }
    }
    func testOverlayRejectsChangedSourcesBeforeAnyWrite() throws {
        let workspace = try temporary()
        let runtime = workspace.appendingPathComponent("runtime")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        let file = runtime.appendingPathComponent("kl_x18.c")
        try Data("changed".utf8).write(to: file)
        XCTAssertThrowsError(try ExperimentalTLS168.apply(to: workspace))
        XCTAssertEqual(try Data(contentsOf: file), Data("changed".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent(".experimental-tls168.json").path))
    }
}
