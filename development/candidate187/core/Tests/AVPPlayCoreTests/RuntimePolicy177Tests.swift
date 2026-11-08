import XCTest
@testable import AVPPlayCore

final class RuntimePolicy177Tests: XCTestCase {
    private struct RecoveryFixture {
        let root: URL
        let runtime: Toolchain
        let recipe: Recipe
        let variant: LocalAPKVariant
        let workspaceRoot: URL
        let workspace: URL
        let app: URL
        let jobs: JobStore
        var job: Job
    }
    func source() throws -> Toolchain {
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["AVPPLAY_TEST_RUNTIME850_RESOURCES"])
        return try OptionalRuntime850.install(resources: URL(fileURLWithPath: path), packager: ToolchainPackager(root: DataLocation.base.appendingPathComponent("toolchains")))
    }
    func recipe() throws -> Recipe {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try RecipeStore(directory: root.appendingPathComponent("recipes")).load(id: "store-3240283705987790")
    }
    private func recoveryFixture() throws -> RecoveryFixture {
        let resources = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["AVPPLAY_TEST_RUNTIME850_RESOURCES"]))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-valid177-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let runtime = try OptionalRuntime850.install(resources: resources,
            packager: ToolchainPackager(root: root.appendingPathComponent("toolchains")))
        let recipe = try recipe(), hash = String(repeating: "a", count: 64)
        let variantID = "\(recipe.id)-recovery-fixture"
        let variant = LocalAPKVariant(id: variantID, recipeID: recipe.id, recipeVersionCode: recipe.versionCode,
            relativePath: "fixture.apk", size: 1, sha256: hash, package: recipe.package,
            versionCode: String(recipe.versionCode), versionName: nil, architectures: ["arm64-v8a"],
            certificateSubjectObserved: nil, androidSignature: nil, source: "local", trustStatus: "fixture",
            official: false, recipeValidated: false, assets: [], sourceRootPath: nil,
            originalAPKSourcePath: nil, packageMatchesRecipe: true, versionMatchesRecipe: true,
            officialAPKHashMatchesRecipe: false, missingRequiredFiles: [], registeredAt: Date())
        let workspaceRoot = root.appendingPathComponent("build-only")
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        let workspaceID = UUID().uuidString.lowercased()
        let workspace = workspaceRoot.appendingPathComponent("\(recipe.toolchain.target)-\(workspaceID)")
        let staged = try IsolatedToolchainWorkspace.stage(from: runtime, to: workspace)
        let tree = workspace.appendingPathComponent(recipe.toolchain.target)
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("lib/arm64-v8a"), withIntermediateDirectories: true)
        try "<manifest package=\"com.twistedpixelgames.PILO\"/>".write(to: tree.appendingPathComponent("AndroidManifest.xml"), atomically: true, encoding: .utf8)
        try Data().write(to: tree.appendingPathComponent("lib/arm64-v8a/libUE4.so"))
        try "local:\(variantID):\(hash) \(recipe.versionCode) icon4 - -".write(
            to: tree.appendingPathComponent(".qi-prepared"), atomically: true, encoding: .utf8)
        try RuntimePolicy177.generatedTargetTableData(in: staged, target: recipe.toolchain.target)
            .write(to: workspace.appendingPathComponent("runtime/kl_target_table.h"))
        let app = workspace.appendingPathComponent("visionos/build/avpplay-build-only/\(workspaceID)/DerivedData/Build/Products/Debug-xros/Fixture.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let build = AppStamp.build(versionCode: recipe.versionCode, toolchainVersion: 850, modified: true)
        let info: [String: Any] = ["CFBundleIdentifier": "test.deadpool", "CFBundleExecutable": "Fixture",
            "CFBundleVersion": build, "CFBundleSupportedPlatforms": ["XROS"],
            "KLTree": recipe.toolchain.target, "KLControllerModeDefault": "standard",
            "KLFrameGenDefault": "off", "KLSurrealAvailable": "NO",
            "KLRoomGuardDefault": "1", "KLGameLanguageDefault": ""]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Info.plist"))
        let executable = app.appendingPathComponent("Fixture")
        try Data([0xcf,0xfa,0xed,0xfe,0x0c,0,0,1,0,0,0,0,2,0,0,0]).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try "KLEPTON_TARGET = \(recipe.toolchain.target)\n** BUILD SUCCEEDED **\n[exit 0]".write(
            to: workspace.appendingPathComponent("build-only.log"), atomically: true, encoding: .utf8)
        var request = InstallRequest(toolchain: runtime.root.path)
        request.localAPKVariantID = variantID
        request.localAssetsSHA256 = try LocalAPKBuildEvidence.assetsHash(variant)
        request.localWorkspaceRoot = workspaceRoot.path; request.bundleId = "test.deadpool"
        request.controllerMode = .standard; request.frameGeneration = .off
        request.surrealSupport = false; request.roomMeasuring = true; request.gameLanguage = ""
        var job = Job(recipe: recipe, request: request, steps: [.buildOnly], toolchainCommit: "cc2856c")
        job.state = .finished; job.completed = [.buildOnly]; job.updated = Date().addingTimeInterval(2)
        let jobs = JobStore(directory: root.appendingPathComponent("jobs"))
        try jobs.save(job)
        let log = "AVPPLAY_BUILD_ONLY_APP_PATH=\(app.path)\nGeneric visionOS app built at \(app.path)."
        try log.write(to: jobs.directory.appendingPathComponent(job.id + ".log"), atomically: true, encoding: .utf8)
        return RecoveryFixture(root: root, runtime: runtime, recipe: recipe, variant: variant,
            workspaceRoot: workspaceRoot, workspace: workspace, app: app, jobs: jobs, job: job)
    }
    func testOldPinsAreIgnoredWithoutSavingAnd850AbsenceHasNoFallback() throws {
        let runtime = try source(), recipe = try recipe()
        let packager = ToolchainPackager(root: runtime.root.deletingLastPathComponent())
        let choices = ToolchainChoices(games: [recipe.id: .init(version: 824, commit: "a61188d")])
        let before = choices
        XCTAssertEqual(packager.selectedToolchain(for: recipe, choices: choices)?.commit(), "cc2856c")
        XCTAssertEqual(choices, before)
        let empty = ToolchainPackager(root: DataLocation.base.appendingPathComponent("absent"))
        XCTAssertNil(empty.selectedToolchain(for: recipe, choices: choices))
        XCTAssertThrowsError(try RuntimePolicy177.source(at: empty.root)) { XCTAssertTrue(String(describing: $0).contains("sem nenhum fallback") || String(describing: $0).contains("nenhum fallback")) }
    }
    func testFullSourceAndTLSWorkspaceVerificationAndTamperRejection() throws {
        let runtime = try source()
        try RuntimePolicy177.requireSource(runtime)
        let original = try Hashing.sha256(of: runtime.root.appendingPathComponent("runtime/kl_x18.c"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("policy177-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let copy = try IsolatedToolchainWorkspace.stage(from: runtime, to: root)
        try RuntimePolicy177.requireWorkspace(copy)
        XCTAssertThrowsError(try RuntimePolicy177.requireSource(copy), "Overlaid copy is never confused with the immutable source")
        try Data("tampered".utf8).write(to: root.appendingPathComponent("runtime/kl_x18.c"))
        XCTAssertThrowsError(try RuntimePolicy177.requireWorkspace(copy))
        XCTAssertEqual(try Hashing.sha256(of: runtime.root.appendingPathComponent("runtime/kl_x18.c")), original)
        let evidence = try RuntimePolicy177.evidence()
        XCTAssertEqual(evidence["Runtime.overlay"], "850-cc2856c-tls168")
        XCTAssertEqual(evidence["Runtime.overlaySHA256"]?.count, 64)
    }
    func testBuildOnlyRecoveryPreservesReusableBuildRejectionReasonAndPath() throws {
        let resources = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["AVPPLAY_TEST_RUNTIME850_RESOURCES"]))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-diagnostics177-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try OptionalRuntime850.install(resources: resources,
            packager: ToolchainPackager(root: root.appendingPathComponent("toolchains")))
        let recipe = try recipe(), hash = String(repeating: "a", count: 64)
        let variantID = "\(recipe.id)-diagnostic-fixture"
        let variant = LocalAPKVariant(id: variantID, recipeID: recipe.id, recipeVersionCode: recipe.versionCode,
            relativePath: "fixture.apk", size: 1, sha256: hash, package: recipe.package,
            versionCode: String(recipe.versionCode), versionName: nil, architectures: ["arm64-v8a"],
            certificateSubjectObserved: nil, androidSignature: nil, source: "local", trustStatus: "fixture",
            official: false, recipeValidated: false, assets: [], sourceRootPath: nil,
            originalAPKSourcePath: nil, packageMatchesRecipe: true, versionMatchesRecipe: true,
            officialAPKHashMatchesRecipe: false, missingRequiredFiles: [], registeredAt: Date())

        let workspaceRoot = root.appendingPathComponent("build-only")
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        let workspaceID = UUID().uuidString.lowercased()
        let workspace = workspaceRoot.appendingPathComponent("\(recipe.toolchain.target)-\(workspaceID)")
        _ = try IsolatedToolchainWorkspace.stage(from: runtime, to: workspace)

        let app = workspace.appendingPathComponent("visionos/build/avpplay-build-only/\(workspaceID)/DerivedData/Build/Products/Debug-xros/Fixture.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let expectedBuild = AppStamp.build(versionCode: recipe.versionCode, toolchainVersion: 850, modified: true)
        let info: [String: Any] = ["CFBundleIdentifier": "test.deadpool", "CFBundleExecutable": "Fixture",
            "CFBundleVersion": expectedBuild, "CFBundleSupportedPlatforms": ["XROS"],
            "KLTree": recipe.toolchain.target, "KLControllerModeDefault": "standard",
            "KLFrameGenDefault": "off", "KLSurrealAvailable": "NO",
            "KLRoomGuardDefault": "1", "KLGameLanguageDefault": ""]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Info.plist"))
        let executable = app.appendingPathComponent("Fixture")
        try Data([0xcf,0xfa,0xed,0xfe,0x0c,0,0,1,0,0,0,0,2,0,0,0]).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let stamp = workspace.appendingPathComponent("\(recipe.toolchain.target)/.qi-prepared")
        try FileManager.default.createDirectory(at: stamp.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stamp.deletingLastPathComponent().appendingPathComponent("lib/arm64-v8a"), withIntermediateDirectories: true)
        try "<manifest package=\"com.twistedpixelgames.PILO\"/>".write(
            to: stamp.deletingLastPathComponent().appendingPathComponent("AndroidManifest.xml"), atomically: true, encoding: .utf8)
        try Data().write(to: stamp.deletingLastPathComponent().appendingPathComponent("lib/arm64-v8a/libUE4.so"))
        try "local:\(variantID):\(hash) \(recipe.versionCode) icon4 - -".write(to: stamp, atomically: true, encoding: .utf8)
        try RuntimePolicy177.generatedTargetTableData(in: Toolchain(root: workspace), target: recipe.toolchain.target)
            .write(to: workspace.appendingPathComponent("runtime/kl_target_table.h"))
        try "KLEPTON_TARGET = \(recipe.toolchain.target)\n** BUILD SUCCEEDED **\n[exit 0]".write(
            to: workspace.appendingPathComponent("build-only.log"), atomically: true, encoding: .utf8)

        var request = InstallRequest(toolchain: runtime.root.path)
        request.localAPKVariantID = variantID
        request.localAssetsSHA256 = try LocalAPKBuildEvidence.assetsHash(variant)
        request.localWorkspaceRoot = workspaceRoot.path
        request.bundleId = "test.deadpool"
        request.controllerMode = .standard; request.frameGeneration = .off
        request.surrealSupport = false; request.roomMeasuring = true; request.gameLanguage = ""
        var job = Job(recipe: recipe, request: request, steps: [.buildOnly], toolchainCommit: "cc2856c")
        job.state = .finished; job.completed = [.buildOnly]; job.updated = .distantPast
        let jobs = JobStore(directory: root.appendingPathComponent("jobs"))
        try jobs.save(job)
        try "AVPPLAY_BUILD_ONLY_APP_PATH=\(app.path)\n".write(
            to: jobs.directory.appendingPathComponent(job.id + ".log"), atomically: true, encoding: .utf8)

        var reports: [String] = []
        XCTAssertThrowsError(try LocalBuildRecovery(workspaceRoot: workspaceRoot).artifact(
            jobs: jobs, recipe: recipe, variant: variant, toolchain: runtime,
            report: { reports.append($0) })) { error in
                let detail = String(describing: error)
                XCTAssertTrue(detail.contains("Build anterior modificado ou sem metadados confiáveis"), detail)
                XCTAssertTrue(detail.contains(workspaceRoot.path), detail)
                XCTAssertTrue(detail.contains(workspace.lastPathComponent), detail)
                XCTAssertTrue(detail.contains("Fixture"), detail)
            }
        XCTAssertTrue(reports.contains { $0.contains("Build anterior modificado ou sem metadados confiáveis") },
                      reports.joined(separator: "\n"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspaceRoot.appendingPathComponent(".build-receipts/\(job.id).json").path),
                       "Rejected artifacts must not gain a synthesized receipt")
    }
    func testBuildOnlyRecoveryAcceptsExactJobWorkspaceAndGeneratedTable() throws {
        let f = try recoveryFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let recovered = try XCTUnwrap(LocalBuildRecovery(workspaceRoot: f.workspaceRoot).artifact(
            jobs: f.jobs, recipe: f.recipe, variant: f.variant, toolchain: f.runtime))
        XCTAssertEqual(recovered.0.app.standardizedFileURL.path, f.app.standardizedFileURL.path)
        XCTAssertEqual(recovered.0.workspace.standardizedFileURL.path, f.workspace.standardizedFileURL.path)
        XCTAssertEqual(recovered.1.id, f.job.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.workspaceRoot.appendingPathComponent(".build-receipts/\(f.job.id).json").path))
    }
    func testBuildOnlyRecoveryRejectsTamperedGeneratedTargetTable() throws {
        let f = try recoveryFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try Data("arbitrary".utf8).write(to: f.workspace.appendingPathComponent("runtime/kl_target_table.h"))
        var diagnostics: [String] = []
        XCTAssertThrowsError(try LocalBuildRecovery(workspaceRoot: f.workspaceRoot).artifact(
            jobs: f.jobs, recipe: f.recipe, variant: f.variant, toolchain: f.runtime,
            report: { diagnostics.append($0) }))
        XCTAssertTrue(diagnostics.joined(separator: "\n").contains("kl_target_table.h"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.workspaceRoot.appendingPathComponent(".build-receipts/\(f.job.id).json").path))
    }
    func testBuildOnlyRecoveryRejectsWrongWorkspaceFromJobLog() throws {
        let f = try recoveryFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let wrong = f.workspaceRoot.appendingPathComponent("beatsaber-\(UUID().uuidString)")
            .appendingPathComponent("visionos/build/avpplay-build-only/wrong/DerivedData/Build/Products/Debug-xros/Other.app")
        try "AVPPLAY_BUILD_ONLY_APP_PATH=\(wrong.path)\n".write(
            to: f.jobs.directory.appendingPathComponent(f.job.id + ".log"), atomically: true, encoding: .utf8)
        var diagnostics: [String] = []
        XCTAssertThrowsError(try LocalBuildRecovery(workspaceRoot: f.workspaceRoot).artifact(
            jobs: f.jobs, recipe: f.recipe, variant: f.variant, toolchain: f.runtime,
            report: { diagnostics.append($0) }))
        XCTAssertTrue(diagnostics.joined(separator: "\n").contains("workspace exato"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.workspaceRoot.appendingPathComponent(".build-receipts/\(f.job.id).json").path))
    }
    func testBuildOnlyRecoveryIgnoresIncompatibleJobCommit() throws {
        let f = try recoveryFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        var incompatible = f.job; incompatible.toolchainCommit = "a61188d"
        try f.jobs.save(incompatible)
        XCTAssertThrowsError(try LocalBuildRecovery(workspaceRoot: f.workspaceRoot).artifact(
            jobs: f.jobs, recipe: f.recipe, variant: f.variant, toolchain: f.runtime))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.workspaceRoot.appendingPathComponent(".build-receipts/\(f.job.id).json").path))
    }
    func test824CannotEnterPrepareBuildOrArtifactSigning() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("old177-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("visionos"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("fixture".utf8).write(to: root.appendingPathComponent("visionos/run.sh"))
        let manifest = ToolchainManifest(format: 1, version: 824, commit: "a61188d", ancestors: [], created: Date())
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: root.appendingPathComponent("toolchain.json"))
        let old = try Toolchain(root: root), recipe = try recipe()
        XCTAssertThrowsError(try RuntimePolicy177.requireSource(old))
        XCTAssertThrowsError(try old.prepare(recipe: recipe, store: ContentStore(root: root.appendingPathComponent("store"))))
        XCTAssertThrowsError(try BuildOnlyPipeline.build(toolchainRoot: root, recipe: recipe,
            store: ContentStore(root: root.appendingPathComponent("store")), bundleID: "test.game", appVersion: "1", appBuild: "1.824", workspaceRoot: root.appendingPathComponent("build"),
            process: { _, _ in XCTFail("No compiler/device/sign process may run"); return 1 }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("build").path))
        let installer = Installer(recipe: recipe, request: InstallRequest(toolchain: root.path), store: ContentStore(root: root.appendingPathComponent("store")), report: { _ in })
        for step in [InstallStep.buildOnly, .build, .stage] {
            do { try await installer.perform(step); XCTFail("824 must block before any operation") } catch { XCTAssertTrue(String(describing: error).contains("Build177")) }
        }
    }
    func testLegacyJobsAndReceiptsRemainReadableAndCannotBeExecutedOrReused() async throws {
        let runtime = try source(), recipe = try recipe()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("history177-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let jobs = JobStore(directory: root.appendingPathComponent("jobs"))
        var request = InstallRequest(toolchain: "/legacy/824"); request.localAPKVariantID = "old-variant"
        var job = Job(recipe: recipe, request: request, steps: [.buildOnly], toolchainCommit: "a61188d")
        try jobs.save(job)
        let original = try Data(contentsOf: jobs.url(job.id))
        do { _ = try await JobRunner(store: jobs).run(job, currentToolchain: "cc2856c", perform: { _, _ in XCTFail("Legacy Job must not execute") }); XCTFail("Expected block") } catch {}
        XCTAssertEqual(try Data(contentsOf: jobs.url(job.id)), original)
        job.state = .finished; job.completed = [.buildOnly]
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(job), log = Data("historical only".utf8)
        let artifact = ReusableBuild(app: root.appendingPathComponent("Old.app"), workspace: root.appendingPathComponent("old"), sourceJobID: job.id, bundleID: "test.game", files: [:])
        let row: [String:Any] = ["jobData":data.base64EncodedString(), "logData":log.base64EncodedString(), "jobSHA256":Hashing.sha256(of:data), "logSHA256":Hashing.sha256(of:log), "artifact":try JSONSerialization.jsonObject(with: JSONEncoder().encode(artifact))]
        let historical = try JSONDecoder().decode(LocalBuildReceipt.self, from: JSONSerialization.data(withJSONObject: row))
        XCTAssertEqual(try historical.job().toolchainCommit, "a61188d")
        XCTAssertThrowsError(try RuntimePolicy177.requireArtifact(artifact))
        XCTAssertThrowsError(try LocalBuildReceipt(jobData: data, logData: log, artifact: artifact))
        XCTAssertNotNil(runtime)
    }
    func testForgedReceiptCannotAuthorizeChanged850Source() throws {
        let runtime = try source()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("forged177-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: runtime.root, to: root)
        let file = root.appendingPathComponent("Makefile")
        try Data("changed".utf8).write(to: file)
        let receipt = root.appendingPathComponent(".isolated-source-sha256.json")
        var hashes = try JSONDecoder().decode([String:String].self, from: Data(contentsOf: receipt))
        hashes["Makefile"] = try Hashing.sha256(of: file)
        try JSONEncoder().encode(hashes).write(to: receipt)
        XCTAssertThrowsError(try RuntimePolicy177.requireSource(Toolchain(root: root)))
    }

    func testNew850TLSReceiptBindsRuntimeAndRejects824StampedArtifact() throws {
        let runtime = try source(), recipe = try recipe()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("receipt177-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceRoot = root.appendingPathComponent("build-only")
        let workspaceID = UUID().uuidString.lowercased()
        let workspace = workspaceRoot.appendingPathComponent("\(recipe.toolchain.target)-\(workspaceID)")
        let staged = try IsolatedToolchainWorkspace.stage(from: runtime, to: workspace)
        let target = workspace.appendingPathComponent(recipe.toolchain.target)
        try FileManager.default.createDirectory(at: target.appendingPathComponent("lib/arm64-v8a"), withIntermediateDirectories: true)
        try "<manifest package=\"com.twistedpixelgames.PILO\"/>".write(to: target.appendingPathComponent("AndroidManifest.xml"), atomically: true, encoding: .utf8)
        try Data().write(to: target.appendingPathComponent("lib/arm64-v8a/libUE4.so"))
        try Data("prepared".utf8).write(to: target.appendingPathComponent(".qi-prepared"))
        try RuntimePolicy177.generatedTargetTableData(in: staged, target: recipe.toolchain.target)
            .write(to: workspace.appendingPathComponent("runtime/kl_target_table.h"))
        let app = workspace.appendingPathComponent("visionos/build/avpplay-build-only/\(workspaceID)/DerivedData/Build/Products/Debug-xros/Fixture.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        var info: [String:Any] = ["CFBundleIdentifier":"test.game", "CFBundleExecutable":"Game", "CFBundleVersion":AppStamp.build(versionCode:1,toolchainVersion:850,modified:true)]
        let plist = app.appendingPathComponent("Info.plist")
        try PropertyListSerialization.data(fromPropertyList: info, format:.xml, options:0).write(to:plist)
        try Data([0xcf,0xfa,0xed,0xfe,0x0c,0,0,1,0,0,0,0,2,0,0,0]).write(to:app.appendingPathComponent("Game"))
        var request = InstallRequest(toolchain: runtime.root.path); request.localAPKVariantID = "fixture"
        request.localWorkspaceRoot = workspaceRoot.path; request.bundleId = "test.game"
        var job = Job(recipe:recipe,request:request,steps:[.buildOnly],toolchainCommit:"cc2856c")
        job.state = .finished; job.completed = [.buildOnly]
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let artifact = ReusableBuild(app:app,workspace:workspace,sourceJobID:job.id,bundleID:"test.game",files:try ReusableBuild.inventory(app))
        let log = Data("AVPPLAY_BUILD_ONLY_APP_PATH=\(app.path)\n".utf8)
        let receipt = try LocalBuildReceipt(jobData:encoder.encode(job),logData:log,artifact:artifact)
        XCTAssertEqual(receipt.toolchainVersion,850); XCTAssertEqual(receipt.toolchainCommit,"cc2856c")
        XCTAssertEqual(receipt.tls168Revision,RuntimePolicy177.revision)
        XCTAssertEqual(receipt.tls168OverlaySHA256,try RuntimePolicy177.evidence()["Runtime.overlaySHA256"])
        info["CFBundleVersion"] = "1.824"
        try PropertyListSerialization.data(fromPropertyList:info,format:.xml,options:0).write(to:plist)
        let old = ReusableBuild(app:app,workspace:workspace,sourceJobID:job.id,bundleID:"test.game",files:try ReusableBuild.inventory(app))
        XCTAssertThrowsError(try RuntimePolicy177.requireArtifact(old))
    }

    func test850ControlsAndGraphicsPreferencesReachRuntimeEnvironment() throws {
        let runtime = try source(), recipe = try recipe()
        try RuntimePolicy177.requireSource(runtime)
        XCTAssertTrue(runtime.supportsRuntime824)
        XCTAssertTrue(runtime.supportsMetalFX)
        XCTAssertTrue(runtime.supportsRenderScalePreset)
        XCTAssertTrue(runtime.supportsXRPrediction)
        XCTAssertTrue(runtime.supportsSurrealControllers)
        var request = InstallRequest(toolchain: runtime.root.path)
        request.controllerMode = .surreal
        request.surrealSDK = .bluetooth
        request.frameGeneration = .between
        request.experimental = true
        request.metalFX = true
        request.xrPrediction = true
        request.resolution = 75
        let environment = try runtime.runtimeEnvironment(recipe: recipe, request: request)
        XCTAssertEqual(environment["KLEPTON_CONTROLLER_MODE"], "surreal")
        XCTAssertEqual(environment["KLEPTON_SURREAL_SUPPORT"], "1")
        XCTAssertEqual(environment["KLEPTON_SURREAL_SDK"], "0")
        XCTAssertEqual(environment["KLEPTON_FRAMEGEN"], "between")
        XCTAssertTrue(environment["KLEPTON_TEST_ON", default: ""].contains(Toolchain.metalFXSwitch))
        XCTAssertTrue(environment["KLEPTON_TEST_ON", default: ""].contains(Toolchain.xrPredictionSwitch))
        XCTAssertEqual(environment[Toolchain.renderScaleVariable], "0.75")
    }

    func testXcodePermissionMigrationRequiresExactSourceTargetAndCompiledValues() throws {
        _ = try source()
        let f = try recoveryFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let originalURL = RuntimePolicy177.sourceRoot.appendingPathComponent("visionos/Info.plist")
        let original = try ReusableBuild.infoPlist(originalURL)
        let originalHash = try Hashing.sha256(of: originalURL)
        let keys = ["NSAccessoryTrackingUsageDescription", "NSBluetoothAlwaysUsageDescription",
                    "NSHandsTrackingUsageDescription", "NSLocalNetworkUsageDescription",
                    "NSMicrophoneUsageDescription", "NSWorldSensingUsageDescription"]
        var workspace = original
        var compiled = try ReusableBuild.infoPlist(f.app.appendingPathComponent("Info.plist"))
        var settings: [String: Any] = [:]
        for key in keys {
            let value = try XCTUnwrap(original[key] as? String)
            workspace.removeValue(forKey: key); compiled[key] = value
            settings["INFOPLIST_KEY_" + key] = value
        }
        let plistURL = f.workspace.appendingPathComponent("visionos/Info.plist")
        let appPlist = f.app.appendingPathComponent("Info.plist")
        let project = f.workspace.appendingPathComponent("visionos/Fixture.xcodeproj/project.pbxproj")
        try FileManager.default.createDirectory(at: project.deletingLastPathComponent(), withIntermediateDirectories: true)
        func write(_ dictionary: [String: Any], _ url: URL) throws {
            try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0).write(to: url)
        }
        func writeProject(_ selected: [String: Any]) throws {
            try write(["objects": [
                "target": ["isa": "PBXNativeTarget", "name": "Fixture", "buildConfigurationList": "list"],
                "list": ["buildConfigurations": ["debug", "release"]],
                "debug": ["isa": "XCBuildConfiguration", "buildSettings": selected],
                "release": ["isa": "XCBuildConfiguration", "buildSettings": settings],
                "projectDebug": ["isa": "XCBuildConfiguration", "buildSettings": [:]]]], project)
        }
        try write(workspace, plistURL); try write(compiled, appPlist); try writeProject(settings)
        func accepted() throws -> Bool {
            try RuntimePolicy177.permittedXcodeInfoPlist(in: Toolchain(root: f.workspace), originalHash: originalHash, app: f.app)
        }
        XCTAssertTrue(try accepted(), "Project-level inherited settings must be accepted")
        try RuntimePolicy177.requireWorkspace(Toolchain(root: f.workspace), generatedTarget: f.recipe.toolchain.target, xcodeBuiltApp: f.app)
        XCTAssertThrowsError(try RuntimePolicy177.requireWorkspace(Toolchain(root: f.workspace), generatedTarget: f.recipe.toolchain.target), "No built app means no migration exception")
        for key in keys {
            var wrong = compiled; wrong[key] = "altered"; try write(wrong, appPlist)
            XCTAssertFalse(try accepted(), key)
            try write(compiled, appPlist)
            var badSettings = settings; badSettings.removeValue(forKey: "INFOPLIST_KEY_" + key)
            try writeProject(badSettings); XCTAssertFalse(try accepted(), key)
            try writeProject(settings)
        }
        var tampered = workspace; tampered["UnexpectedPermission"] = true
        try write(tampered, plistURL); XCTAssertFalse(try accepted())
        try write(workspace, plistURL)
        XCTAssertFalse(try RuntimePolicy177.permittedXcodeInfoPlist(in: Toolchain(root: f.workspace), originalHash: String(repeating: "0", count: 64), app: f.app))
        let outside = f.root.appendingPathComponent("Outside.app")
        try FileManager.default.copyItem(at: f.app, to: outside)
        XCTAssertFalse(try RuntimePolicy177.permittedXcodeInfoPlist(in: Toolchain(root: f.workspace), originalHash: originalHash, app: outside))
    }

}
