import XCTest
@testable import AVPPlayCore

final class Build170Tests: XCTestCase {
    func testRuntime850StagingTLSAndTamperRejectionWithDisposablePayload() throws {
        guard let path = ProcessInfo.processInfo.environment["AVPPLAY_TEST_RUNTIME850_RESOURCES"] else { throw XCTSkip("Explicit disposable 850 fixture required") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("runtime170-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let packager = ToolchainPackager(root: root.appendingPathComponent("toolchains"))
        let runtime = try OptionalRuntime850.install(resources: URL(fileURLWithPath: path), packager: packager)
        XCTAssertEqual(try OptionalRuntime850.verifyFullIntegrity(of: runtime), 2116)
        XCTAssertEqual(runtime.commit(), "cc2856c")
        XCTAssertEqual(runtime.version(), 850)
        XCTAssertEqual(try RuntimeInterface.scan(klepton: runtime.root).commit, "cc2856c")
        let staged = root.appendingPathComponent("staged")
        try OptionalRuntime850.stageVerifiedPayload(from: runtime, to: staged)
        XCTAssertTrue(try Toolchain(root: staged).isModified)
        XCTAssertEqual(try OptionalRuntime850.verifyFullIntegrity(of: runtime), 2116)
        let manifest = try XCTUnwrap(Bundle.module.url(forResource: "tls170-overlay", withExtension: "json"))
        let overlay = try JSONDecoder().decode(ExperimentalTLS170.Overlay.self, from: Data(contentsOf: manifest))
        for file in overlay.files {
            XCTAssertEqual(try Hashing.sha256(of: staged.appendingPathComponent(file.path)), file.correctedSHA256)
            XCTAssertEqual(try Hashing.sha256(of: runtime.root.appendingPathComponent(file.path)), file.originalSHA256)
        }
        XCTAssertThrowsError(try ExperimentalTLS170.apply(to: staged))
        try Data("tampered".utf8).write(to: runtime.root.appendingPathComponent("runtime/kl_x18.c"))
        XCTAssertThrowsError(try OptionalRuntime850.verifyFullIntegrity(of: runtime))
        XCTAssertThrowsError(try OptionalRuntime850.stageVerifiedPayload(from: runtime, to: root.appendingPathComponent("rejected")))
    }

    func testIncompleteLocalEvidenceIsUnknownEvenWithASimilarReference() {
        var fp = Fingerprint()
        let runtime = RuntimeInterface(functions: ["openxr": ["xrCreateSession"]], openxrExtensions: [])
        let refs = [ReferenceFingerprint(id: "reference", title: "Verified", fingerprint: fp)]
        XCTAssertNil(LocalPrognosis170.assess(fp, runtime: runtime, references: refs))
        fp.architectures = ["arm64-v8a"]; fp.libraries = ["libunity.so"]; fp.engine = .unity; fp.interfaces = [.openxr]
        XCTAssertNil(LocalPrognosis170.assess(fp, runtime: nil, references: refs))
        XCTAssertNil(LocalPrognosis170.assess(fp, runtime: runtime, references: []))
        XCTAssertNotNil(LocalPrognosis170.assess(fp, runtime: runtime, references: refs))
    }

    func testConsentNeverFollowsFromImportAnalysisOrMissingIdentity() {
        XCTAssertFalse(FingerprintConsent170.allows(enabled: false, explicitAction: true, online: true, game: "123456789"))
        XCTAssertFalse(FingerprintConsent170.allows(enabled: true, explicitAction: false, online: true, game: "123456789"))
        XCTAssertFalse(FingerprintConsent170.allows(enabled: true, explicitAction: true, online: false, game: "123456789"))
        XCTAssertFalse(FingerprintConsent170.allows(enabled: true, explicitAction: true, online: true, game: nil))
        XCTAssertFalse(FingerprintConsent170.allows(enabled: true, explicitAction: true, online: true, game: "com.personal.game"))
        XCTAssertTrue(FingerprintConsent170.allows(enabled: true, explicitAction: true, online: true, game: "123456789"))
    }

    func testSharedPayloadContainsOnlyAuditedTechnicalFields() throws {
        var fp = Fingerprint()
        fp.package = "com.personal.secret"; fp.permissions = ["personal.permission"]
        fp.javaPackages = ["private.name"]; fp.jniClasses = ["private/Class"]
        fp.metaData = ["secret metadata"]; fp.libraries = ["secret library"]
        let data = try JSONEncoder().encode(SharedFingerprint(fp))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["format", "engine", "graphics", "interfaces", "imported", "openxrExtensions", "middleware", "features"])
        let text = String(decoding: data, as: UTF8.self)
        for forbidden in ["personal", "private", "secret", "sha256", "apk", "obb", "asset"] { XCTAssertFalse(text.contains(forbidden)) }
    }
    func testFingerprintRequestHasOnlyAuditedEnvelopeAndNoCookies() throws {
        let request = try CatalogClient(base: URL(string: "https://invalid.example")!).fingerprintRequest(
            SharedFingerprint(Fingerprint()), game: "123456789", versionCode: 42)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["appId", "versionCode", "fingerprint"])
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(request.httpMethod, "POST")
    }
    func test850BrinkOBBRuleRequiresExactPackageAndDoesNotAlter824Rules() {
        XCTAssertEqual(Klepton850RecipeRules.obbOverride(target: "x3635172946605196", package: "com.brink.vr.oculus.quest"),
                       "android-files/Android/obb/com.brink.vr.oculus.quest")
        XCTAssertNil(Klepton850RecipeRules.obbOverride(target: "x3635172946605196", package: "com.other.game"))
        XCTAssertNil(Klepton824RecipeRules.obbOverride(target: "x3635172946605196", package: "com.brink.vr.oculus.quest"))
    }

    func testNoOfflineModeInRequestOrPersistedBuildDefaults() throws {
        let request = try JSONEncoder().encode(InstallRequest(toolchain: "/fixture"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: request) as? [String: Any])
        XCTAssertNil(object["offline"])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("defaults170-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try InstallDefaults.setRoomMeasuring(true, base: root)
        let defaults = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("install-defaults.json"))) as? [String: Any])
        XCTAssertNil(defaults["offline"])
    }

}
