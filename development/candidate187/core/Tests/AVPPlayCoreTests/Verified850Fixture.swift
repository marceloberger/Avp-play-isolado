import XCTest
@testable import AVPPlayCore

/// Test-only fixtures. Runtime bytes come from the pinned archive installer, never from
/// a mutable installed toolchain. All game inputs, logs, Jobs and ARM64 headers are synthetic.
enum Verified850Fixture {
    static func source() throws -> Toolchain {
        let env = ProcessInfo.processInfo.environment
        let home = try XCTUnwrap(env["AVPPLAY_HOME"], "Disposable AVPPLAY_HOME is mandatory")
        let declaredRoot = URL(fileURLWithPath: try XCTUnwrap(env["AVPPLAY_TEST_FIXTURE_ROOT"]))
            .resolvingSymlinksInPath().standardizedFileURL.path
        let isolated = URL(fileURLWithPath: home).resolvingSymlinksInPath().standardizedFileURL.path
        let temporary = URL(fileURLWithPath: "/private/tmp").resolvingSymlinksInPath().standardizedFileURL.path
        guard declaredRoot.hasPrefix(temporary + "/avp-base179-affected36-"),
              isolated == declaredRoot + "/data",
              DataLocation.base.resolvingSymlinksInPath().standardizedFileURL.path == isolated else {
            throw LocalAPKVariantError.invalidRecord("Fixture data is outside its explicit disposable root: declared=\(declaredRoot), temporary=\(temporary), isolated=\(isolated), effective=\(DataLocation.base.resolvingSymlinksInPath().standardizedFileURL.path)")
        }
        let resources = URL(fileURLWithPath: try XCTUnwrap(env["AVPPLAY_TEST_RUNTIME850_RESOURCES"]))
        let runtime = try OptionalRuntime850.install(resources: resources,
            packager: ToolchainPackager(root: DataLocation.base.appendingPathComponent("toolchains")))
        try RuntimePolicy177.requireSource(runtime) // pinned 2116-file manifest, SDK and TLS input hashes
        return runtime
    }
    static func workspace(at path: URL) throws -> Toolchain {
        let copy = try IsolatedToolchainWorkspace.stage(from: source(), to: path)
        try RuntimePolicy177.requireWorkspace(copy)
        return copy
    }
    struct Build {
        let runtime: Toolchain, workspace: Toolchain, app: URL, workspaceRoot: URL
        let recipe: Recipe, variant: LocalAPKVariant, jobs: JobStore
        let request: InstallRequest, job: Job, artifact: ReusableBuild, log: String
    }
    static func build(root: URL, recipe: Recipe, variant selected: LocalAPKVariant? = nil,
                      bundle: String = "test.fixture.game", room: Bool = true,
                      workspaceRoot requestedRoot: URL? = nil) throws -> Build {
        let runtime = try source(), target = KleptonRecipeCompatibility.resolve(recipe).toolchain.target
        let hash = String(repeating: "a", count: 64), id = "synthetic-variant"
        let variant = selected ?? LocalAPKVariant(id: id, recipeID: recipe.id,
            recipeVersionCode: recipe.versionCode, relativePath: "not-read.apk", size: 1, sha256: hash,
            package: recipe.package, versionCode: String(recipe.versionCode), architectures: ["arm64-v8a"],
            source: "synthetic", trustStatus: "fixture", official: false, recipeValidated: false, registeredAt: Date())
        let parent = requestedRoot ?? root.appendingPathComponent("build-only")
        let uuid = UUID().uuidString.lowercased()
        let workspace = try self.workspace(at: parent.appendingPathComponent("\(target)-\(uuid)"))
        let tree = workspace.root.appendingPathComponent(target)
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("lib/arm64-v8a"), withIntermediateDirectories: true)
        try "<manifest package=\"\(recipe.package)\"/>".write(to: tree.appendingPathComponent("AndroidManifest.xml"), atomically: true, encoding: .utf8)
        try "versionInfo:\n  versionCode: \(recipe.versionCode)\n".write(to: tree.appendingPathComponent("apktool.yml"), atomically: true, encoding: .utf8)
        for name in ["libUE4.so", "libunity.so", "libil2cpp.so", "libmain.so"] {
            try Data().write(to: tree.appendingPathComponent("lib/arm64-v8a/" + name))
        }
        try "local:\(variant.id):\(variant.sha256) \(recipe.versionCode) icon4 - -".write(to: tree.appendingPathComponent(".qi-prepared"), atomically: true, encoding: .utf8)
        try RuntimePolicy177.generatedTargetTableData(in: workspace, target: target)
            .write(to: workspace.root.appendingPathComponent("runtime/kl_target_table.h"))
        try RuntimePolicy177.requireWorkspace(workspace, generatedTarget: target)
        let app = workspace.root.appendingPathComponent("visionos/build/avpplay-build-only/\(uuid)/DerivedData/Build/Products/Debug-xros/Fixture.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": bundle, "CFBundleExecutable": "Fixture",
            "CFBundleVersion": AppStamp.build(versionCode: recipe.versionCode, toolchainVersion: 850, modified: true),
            "CFBundleSupportedPlatforms": ["XROS"], "KLTree": target, "KLControllerModeDefault": "standard",
            "KLFrameGenDefault": "off", "KLSurrealAvailable": "NO", "KLRoomGuardDefault": room ? "1" : "0", "KLGameLanguageDefault": ""]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Info.plist"))
        try Data([0xcf,0xfa,0xed,0xfe,0x0c,0,0,1,0,0,0,0,2,0,0,0]).write(to: app.appendingPathComponent("Fixture"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: app.appendingPathComponent("Fixture").path)
        // Synthetic success evidence exercises the verifier; no compiler/game process is run.
        try "SYNTHETIC TEST ONLY\nKLEPTON_TARGET = \(target)\n** BUILD SUCCEEDED **\n[exit 0]".write(to: workspace.root.appendingPathComponent("build-only.log"), atomically: true, encoding: .utf8)
        var request = InstallRequest(toolchain: runtime.root.path)
        request.localAPKVariantID = variant.id; request.localWorkspaceRoot = parent.path
        request.localAssetsSHA256 = try LocalAPKBuildEvidence.assetsHash(variant)
        request.bundleId = bundle; request.controllerMode = .standard; request.frameGeneration = .off
        request.surrealSupport = false; request.roomMeasuring = room; request.gameLanguage = ""
        var job = Job(recipe: recipe, request: request, steps: [.buildOnly], toolchainCommit: "cc2856c")
        job.state = .finished; job.completed = [.buildOnly]; job.updated = Date().addingTimeInterval(2)
        let jobs = JobStore(directory: root.appendingPathComponent("jobs")); try jobs.save(job)
        let log = "SYNTHETIC TEST ONLY\nAVPPLAY_BUILD_ONLY_APP_PATH=\(app.path)\n"
        try log.write(to: jobs.directory.appendingPathComponent(job.id + ".log"), atomically: true, encoding: .utf8)
        let artifact = ReusableBuild(app: app, workspace: workspace.root, sourceJobID: job.id, bundleID: bundle, files: try ReusableBuild.inventory(app))
        try RuntimePolicy177.requireArtifact(artifact, target: target)
        return Build(runtime: runtime, workspace: workspace, app: app, workspaceRoot: parent,
            recipe: recipe, variant: variant, jobs: jobs, request: request, job: job, artifact: artifact, log: log)
    }
}
