import XCTest
@testable import AVPPlayCore

final class LocalExperimentalAdmissionTests: XCTestCase {
    struct Fixture {
        let root: URL, input: URL, apk: URL, recipe: Recipe
        let registry: LocalAPKVariantStore, variant: LocalAPKVariant
    }
    private func fixture(engine: String = "libUE4.so", machine: Int = 183, signed: Bool = true) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("local-flow186-" + UUID().uuidString)
        let input = root.appendingPathComponent("input")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let apk = try LocalAPKVariantTests().makeAPK(in: input, package: "com.example.localflow",
            versionCode: "47", versionName: "1.3.1", nativeLibraries: [engine])
        // An actual ELF64 AArch64 header; the guest is never executed by these tests.
        let rewrite = #"import zipfile,sys; p=sys.argv[1]; z=zipfile.ZipFile(p); files={n:z.read(n) for n in z.namelist()}; z.close(); h=bytearray(64); h[:6]=b'\x7fELF\x02\x01'; h[18:20]=int(sys.argv[2]).to_bytes(2,'little'); w=zipfile.ZipFile(p,'w'); [(w.writestr(n,bytes(h) if n.endswith('.so') else b)) for n,b in files.items()]; w.close()"#
        _ = try ApkUnpacker.run(["/usr/bin/python3", "-c", rewrite, apk.path, String(machine)])
        try FileManager.default.removeItem(at: input.appendingPathComponent("synthetic-apk"))
        if signed { _ = try ApkUnpacker.run(["/usr/bin/python3", "-c", Self.signingScript, root.path, apk.path]) }
        for name in ["main.47.com.example.localflow.obb", "patch.47.com.example.localflow.obb"] {
            try Data(("Synthetic OBB " + name).utf8).write(to: input.appendingPathComponent(name))
        }
        let records = LocalProvisionalRecipeStore(root: root.appendingPathComponent("provisional"))
        let record = try LocalGameImport().createProvisionalAnalysis(from: input, store: records)
        let revised = try records.setExperimentalTarget(appID: "123456789", provenance: "User's local product reference", for: record.id)
        let recipe = try XCTUnwrap(revised.experimentalRecipe, revised.experimentalBlockers.joined(separator: ";"))
        let registry = LocalAPKVariantStore(root: root.appendingPathComponent("variants"))
        let discovery = try LocalGameImport().discover(in: input, recipe: recipe)
        let destinations = LocalGameImport().automaticAdditionalDestinations(for: discovery, recipe: recipe)
        let variant = try LocalGameImport().register(discovery, recipe: recipe, store: registry,
            additionalDestinations: destinations, automaticAdditionalPaths: Set(destinations.keys))
        return Fixture(root: root, input: input, apk: apk, recipe: recipe, registry: registry, variant: variant)
    }

    func testOfflineGenericRecipesForTwoEnginesKeepLocalTrustAndExactInputs() throws {
        for engine in ["libUE4.so", "libUnreal.so"] {
            let f = try fixture(engine: engine)
            XCTAssertEqual(f.recipe.toolchain.target, DraftRecipe.genericTarget(appId: "123456789"))
            XCTAssertNil(f.recipe.store.appId)
            XCTAssertNil(f.recipe.addons)
            XCTAssertEqual(f.recipe.status.playability, "untested")
            XCTAssertEqual(f.variant.trustStatus, "local-unverified")
            XCTAssertFalse(f.variant.official)
            XCTAssertFalse(f.variant.recipeValidated)
            XCTAssertEqual(f.variant.assets?.count, 2)
            XCTAssertNoThrow(try LocalExperimentalAdmission.requireEligible(recipe: f.recipe, variant: f.variant))
            let selected = try f.registry.validatedForPreparation(id: f.variant.id, for: f.recipe)
            XCTAssertNoThrow(try LocalExperimentalAdmission.requireValidated(recipe: f.recipe, selected: selected))
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("jobs").path))
        }
    }

    func testMetadataCannotPromoteTrustOrSubstitutePackageVersionHashSignatureOrAssets() throws {
        let f = try fixture()
        var cases: [LocalAPKVariant] = []
        var v = f.variant; v.package = "com.other.game"; cases.append(v)
        v = f.variant; v.versionCode = "48"; cases.append(v)
        v = f.variant; v.sha256 = String(repeating: "b", count: 64); cases.append(v)
        v = f.variant; v.architectures = ["armeabi-v7a"]; cases.append(v)
        v = f.variant; v.official = true; cases.append(v)
        v = f.variant; v.recipeValidated = true; cases.append(v)
        v = f.variant; v.trustStatus = "verified"; cases.append(v)
        v = f.variant; v.androidSignature = nil; cases.append(v)
        v = f.variant; v.assets = []; cases.append(v)
        v = f.variant; v.assets![0].destination = "android-files/other/main.47.com.example.localflow.obb"; cases.append(v)
        v = f.variant; v.assets![0].destination = "../escape"; cases.append(v)
        v = f.variant; v.assets!.append(v.assets![0]); cases.append(v)
        for invalid in cases { XCTAssertThrowsError(try LocalExperimentalAdmission.requireEligible(recipe: f.recipe, variant: invalid)) }
        var recipe = f.recipe; recipe.status.playability = "verified"
        XCTAssertThrowsError(try LocalExperimentalAdmission.requireEligible(recipe: recipe, variant: f.variant))
        recipe = f.recipe; recipe.store.appId = "123456789"
        XCTAssertThrowsError(try LocalExperimentalAdmission.requireEligible(recipe: recipe, variant: f.variant))
    }

    func testWrongPackageAndVersionOBBsCannotBeRelabelledAsAdditionalAssets() throws {
        let f = try fixture()
        for name in ["main.48.com.example.localflow.obb", "patch.47.com.other.game.obb"] {
            var v = f.variant
            v.assets![0].sourcePath = f.input.appendingPathComponent(name).path
            v.assets![0].destination = "android-files/Android/obb/com.example.localflow/" + name
            XCTAssertThrowsError(try LocalExperimentalAdmission.requireEligible(recipe: f.recipe, variant: v))
        }
    }

    func testUnsignedAndDisguisedWrongArchitectureFailOperationalValidation() throws {
        let unsigned = try fixture(signed: false)
        XCTAssertThrowsError(try LocalExperimentalAdmission.requireEligible(recipe: unsigned.recipe, variant: unsigned.variant))
        let wrong = try fixture(machine: 62)
        let selected = try wrong.registry.validatedForPreparation(id: wrong.variant.id, for: wrong.recipe)
        XCTAssertThrowsError(try LocalExperimentalAdmission.requireValidated(recipe: wrong.recipe, selected: selected))
    }

    func testChangedAPKAndOBBFailBeforeInstallation() throws {
        let f = try fixture()
        _ = try f.registry.validatedForPreparation(id: f.variant.id, for: f.recipe)
        try Data("changed".utf8).write(to: URL(fileURLWithPath: f.variant.assets![0].sourcePath))
        XCTAssertThrowsError(try f.registry.validatedForPreparation(id: f.variant.id, for: f.recipe))
        let g = try fixture()
        try Data("changed".utf8).write(to: g.registry.root.appendingPathComponent(g.variant.relativePath))
        XCTAssertThrowsError(try g.registry.validatedForPreparation(id: g.variant.id, for: g.recipe))
    }

    func testInstallerAccountAndFetchUseOnlyLocalFilesAndBuildStillRequiresAppleTeam() async throws {
        let f = try fixture(), runtime = try Verified850Fixture.source()
        var request = InstallRequest(toolchain: runtime.root.path)
        request.localAPKVariantID = f.variant.id
        request.account = "no-meta-credentials-for-this-local-test"
        request.localVariantStorePath = f.registry.root.path
        let installer = Installer(recipe: f.recipe, request: request,
            store: ContentStore(root: f.root.appendingPathComponent("store")), localVariants: f.registry,
            jobs: JobStore(directory: f.root.appendingPathComponent("jobs")), report: { _ in })
        try await installer.perform(.account)
        try await installer.perform(.fetch)
        do { try await installer.perform(.build); XCTFail("Apple Team must remain mandatory") }
        catch InstallError.teamMissing { }
        do { try await installer.perform(.unlock); XCTFail("Local flow must never unlock licences") }
        catch { XCTAssertTrue(String(describing: error).contains("desbloqueio")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("jobs").path))
    }

    func testMissingLocalVariantAndUnlockAreRejectedBeforeAnyRuntimeOrDeviceAccess() async throws {
        let f = try fixture()
        let installer = Installer(recipe: f.recipe, request: InstallRequest(toolchain: "/nonexistent"),
            store: ContentStore(root: f.root.appendingPathComponent("store")), localVariants: f.registry,
            jobs: JobStore(directory: f.root.appendingPathComponent("jobs")), report: { _ in })
        for step in [InstallStep.account, .fetch, .buildOnly, .build, .stage, .unlock] {
            do { try await installer.perform(step); XCTFail("Missing variant must fail") }
            catch { XCTAssertTrue(String(describing: error).contains("variante local"), String(describing: error)) }
        }
    }

    func testOnlyIntactCurrentBuildIsReusedAndDeletedJobsNeverReappear() throws {
        let f = try fixture()
        let build = try Verified850Fixture.build(root: f.root, recipe: f.recipe, variant: f.variant)
        func find(_ requested: InstallRequest) throws -> (ReusableBuild, Job)? {
            try LocalExperimentalAdmission.existingBuild(jobs: build.jobs, workspaceRoot: build.workspaceRoot,
                recipe: f.recipe, variant: f.variant, toolchain: build.runtime, requested: requested)
        }
        let bytes = try Data(contentsOf: build.jobs.url(build.job.id))
        XCTAssertEqual(try find(build.request)?.0.app.path, build.app.path)
        var changed = build.request; changed.controllerMode = .surreal
        XCTAssertNil(try find(changed))
        changed = build.request; changed.roomMeasuring = false
        XCTAssertNil(try find(changed))
        changed = build.request; changed.gameLanguage = "pt-BR"
        XCTAssertNil(try find(changed))
        changed = build.request; changed.customIcon = "/tmp/new-icon.png"
        XCTAssertNil(try find(changed))
        try Data("tampered".utf8).write(to: build.app.appendingPathComponent("Fixture"))
        XCTAssertNil(try find(build.request))
        XCTAssertEqual(try Data(contentsOf: build.jobs.url(build.job.id)), bytes)
        try FileManager.default.removeItem(at: build.jobs.url(build.job.id))
        XCTAssertNil(try find(build.request))
        XCTAssertFalse(FileManager.default.fileExists(atPath: build.jobs.url(build.job.id).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: build.app.path))
    }

    func testSplitEntrypointAndExplicitOBBDependencyRemainMandatory() throws {
        let f = try fixture()
        let selected = try f.registry.validatedForPreparation(id: f.variant.id, for: f.recipe)
        var apk = selected.inspection
        apk.splitName = "config.arm64"
        XCTAssertThrowsError(try LocalExperimentalAdmission.requireValidated(recipe: f.recipe,
            selected: .init(variant: selected.variant, apk: selected.apk, inspection: apk)))
        apk = selected.inspection; apk.nativeLibraries = []
        XCTAssertThrowsError(try LocalExperimentalAdmission.requireValidated(recipe: f.recipe,
            selected: .init(variant: selected.variant, apk: selected.apk, inspection: apk)))
        apk = selected.inspection
        apk.externalFileReferences = ["main.47.com.missing.dependency.obb"]
        XCTAssertThrowsError(try LocalExperimentalAdmission.requireValidated(recipe: f.recipe,
            selected: .init(variant: selected.variant, apk: selected.apk, inspection: apk)))
    }

    /// Opt-in audit: all caches stay temporary; no preparation receipt, Job or build is written.
    func testExplicitReadOnlyExistingLocalBuild() throws {
        guard let path = ProcessInfo.processInfo.environment["AVPPLAY_READONLY_LOCAL_BUILD_ROOT"] else {
            throw XCTSkip("Requires an explicit read-only data root; never searches installed data automatically")
        }
        let root = URL(fileURLWithPath: path)
        let jobs = JobStore(directory: root.appendingPathComponent("jobs"))
        let candidates = jobs.all().filter { $0.recipe.localExperimental != nil && $0.steps == [.buildOnly] }
        XCTAssertFalse(candidates.isEmpty)
        let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent("read-only-local-audit-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        for job in candidates {
            let store = LocalAPKVariantStore(root: root.appendingPathComponent("local-variants"),
                hashCache: SHA256FileCache(root: cacheRoot))
            let selected = try store.validated(id: XCTUnwrap(job.request.localAPKVariantID),
                for: job.recipe, forceFull: true)
            try LocalExperimentalAdmission.requireValidated(recipe: job.recipe, selected: selected)
            let result = try LocalExperimentalAdmission.existingBuild(jobs: jobs,
                workspaceRoot: root.appendingPathComponent("build-only"), recipe: job.recipe,
                variant: selected.variant, toolchain: Toolchain(root: URL(fileURLWithPath: job.request.toolchain)),
                requested: job.request, report: { print($0) })
            print("READ_ONLY_LOCAL_AUDIT package=\(selected.variant.package) inputs=valid reusable=\(result != nil) job=\(job.id)")
        }
    }
    private static let signingScript = #"""
import pathlib,sys,zipfile,hashlib,base64,subprocess
root=pathlib.Path(sys.argv[1]);apk=pathlib.Path(sys.argv[2])
with zipfile.ZipFile(apk) as z: payload={n:z.read(n) for n in z.namelist() if not n.endswith('/')}
def digest(b):return base64.b64encode(hashlib.sha256(b).digest()).decode()
mf='Manifest-Version: 1.0\r\n\r\n'+''.join('Name: '+n+'\r\nSHA-256-Digest: '+digest(b)+'\r\n\r\n' for n,b in payload.items())
sf=('Signature-Version: 1.0\r\nSHA-256-Digest-Manifest: '+digest(mf.encode())+'\r\n\r\n').encode()
(root/'signature.sf').write_bytes(sf)
subprocess.run(['/usr/bin/openssl','req','-x509','-newkey','rsa:2048','-nodes','-keyout',str(root/'test.key'),'-out',str(root/'test.crt'),'-subj','/CN=AVP Local Test Fixture','-days','1'],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
subprocess.run(['/usr/bin/openssl','smime','-sign','-binary','-in',str(root/'signature.sf'),'-signer',str(root/'test.crt'),'-inkey',str(root/'test.key'),'-outform','DER','-out',str(root/'signature.der')],check=True)
with zipfile.ZipFile(apk,'a') as z:
 z.writestr('META-INF/MANIFEST.MF',mf);z.writestr('META-INF/TEST.SF',sf);z.writestr('META-INF/TEST.RSA',(root/'signature.der').read_bytes())
"""#
}
