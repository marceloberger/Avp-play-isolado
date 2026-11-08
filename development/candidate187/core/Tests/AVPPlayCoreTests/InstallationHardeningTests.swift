import XCTest
import CryptoKit
@testable import AVPPlayCore

final class InstallationHardeningTests: XCTestCase {
    func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("installation-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    func recipe() throws -> Recipe { try ResumeReuseTests().recipe() }

    final class Remote {
        var files: [String: Data] = [:]
        var dates: [String: Date] = [:]
        var uploads: [String] = []
        var reads = 0
        var broken = false
        var failingPath: String?
        var container: InstallationContent.Container {
            .init(stat: { path in
                self.files[path].map { RemoteFile(relativePath: path, size: Int64($0.count), isDirectory: false, modified: self.dates[path]) }
            }, fetch: { path, url in
                self.reads += 1
                guard let bytes = self.files[path] else { throw DeviceError.tool("missing fixture") }
                try bytes.write(to: url)
            }, put: { url, path in
                if path == self.failingPath { throw DeviceError.tool("connection interrupted") }
                let bytes = try Data(contentsOf: url)
                self.files[path] = self.broken ? Data(repeating: 0, count: bytes.count) : bytes
                self.dates[path] = Date()
                self.uploads.append(path)
            })
        }
    }
    func testResumeOnlyUploadsMissingOrDivergentAndPreservesOtherFiles() throws {
        let root = try scratch(), remote = Remote(), receipts = root.appendingPathComponent("receipts.json")
        try write("apk", root.appendingPathComponent("base.apk"))
        try write("metadata", root.appendingPathComponent("manifest"))
        let apk = try InstallationContent.entry(source: root.appendingPathComponent("base.apk"), destination: "Documents/runtime.apk")
        let meta = try InstallationContent.entry(source: root.appendingPathComponent("manifest"), destination: "Documents/zz-other/AndroidManifest.xml")
        remote.files["Documents/save"] = Data("user data".utf8)
        remote.failingPath = meta.destination
        XCTAssertThrowsError(try InstallationContent.sync([apk,meta], container: remote.container, receipts: receipts))
        XCTAssertEqual(remote.uploads, [apk.destination])
        remote.failingPath = nil
        try InstallationContent.sync([apk,meta], container: remote.container, receipts: receipts)
        XCTAssertEqual(remote.uploads, [apk.destination,meta.destination])
        let reads = remote.reads
        try InstallationContent.sync([apk,meta], container: remote.container, receipts: receipts)
        XCTAssertEqual(remote.reads, reads, "trusted SHA receipts avoid rereading unchanged large files")
        remote.files[apk.destination] = Data("bad".utf8)
        remote.dates[apk.destination] = Date().addingTimeInterval(20)
        try InstallationContent.sync([apk,meta], container: remote.container, receipts: receipts)
        XCTAssertEqual(remote.uploads.last, apk.destination)
        XCTAssertEqual(remote.files["Documents/save"], Data("user data".utf8))
    }
    func testSameSizeCorruptionAndBrokenTransferCannotSucceed() throws {
        let root = try scratch(), remote = Remote()
        let file = root.appendingPathComponent("source"); try write("correct",file)
        let entry = try InstallationContent.entry(source: file, destination: "Documents/game.apk")
        remote.files[entry.destination] = Data("corrupt".utf8)
        remote.broken = true
        XCTAssertThrowsError(try InstallationContent.sync([entry], container: remote.container, receipts: root.appendingPathComponent("r")))
        remote.broken = false
        try InstallationContent.sync([entry], container: remote.container, receipts: root.appendingPathComponent("r"))
        XCTAssertEqual(remote.files[entry.destination], Data("correct".utf8))
        XCTAssertThrowsError(try InstallationContent.entry(source: file, destination: entry.destination, expectedHash: String(repeating: "a",count:64)))
        XCTAssertThrowsError(try InstallationContent.entry(source: root.appendingPathComponent("absent"), destination: entry.destination))
    }
    func testNoRemoteTimestampForcesRehashAndDuplicateConflictIsRejected() throws {
        let root = try scratch(), remote = Remote(), a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        try write("aaa",a); try write("bbb",b)
        let one = try InstallationContent.entry(source:a,destination:"Documents/a")
        let two = try InstallationContent.entry(source:b,destination:"Documents/a")
        XCTAssertEqual(try InstallationContent.unique([one,one]).count,1)
        XCTAssertThrowsError(try InstallationContent.unique([one,two]))
        remote.files[one.destination] = Data("aaa".utf8)
        let receipts = root.appendingPathComponent("r")
        try InstallationContent.sync([one],container:remote.container,receipts:receipts)
        try InstallationContent.sync([one],container:remote.container,receipts:receipts)
        XCTAssertEqual(remote.reads,2)
        XCTAssertTrue(remote.uploads.isEmpty)
    }
    func testPreparedMetadataIndependentOfAssetsAndResolvedTarget() throws {
        let root = try scratch(); try write("fixture",root.appendingPathComponent("visionos/run.sh"))
        let tc = try Toolchain(root:root)
        var recipe = try recipe()
        for target in ["x2637179839719680", "different-layout"] {
            recipe.toolchain.target = target
            let actual = KleptonRecipeCompatibility.resolve(recipe).toolchain.target
            let tree = root.appendingPathComponent(actual)
            try write("<manifest package=\"\(recipe.package)\"/>",tree.appendingPathComponent("AndroidManifest.xml"))
            try write("versionInfo:\n  versionCode: 203\n",tree.appendingPathComponent("apktool.yml"))
            let entries = try InstallationContent.prepared(toolchain:tc,recipe:recipe)
            XCTAssertEqual(entries.count,2)
            XCTAssertTrue(entries.allSatisfy { $0.destination.hasPrefix("Documents/\(actual)/") })
            try write("asset",tree.appendingPathComponent("assets/nested/asset"))
            XCTAssertEqual(try InstallationContent.prepared(toolchain:tc,recipe:recipe).count,3)
            try FileManager.default.removeItem(at:tree.appendingPathComponent("apktool.yml"))
            XCTAssertThrowsError(try InstallationContent.prepared(toolchain:tc,recipe:recipe))
        }
        recipe.files = []; XCTAssertTrue(try InstallationContent.prepared(toolchain:tc,recipe:recipe).isEmpty)
    }
    func testPreparedMetadataUsesVerifiedIsolatedBuildWorkspace() throws {
        let root = try scratch()
        try write("fixture", root.appendingPathComponent("visionos/run.sh"))
        let toolchain = try Toolchain(root: root)
        let workspace = root.appendingPathComponent("build-only/job-123", isDirectory: true)
        var recipe = try recipe()
        let target = KleptonRecipeCompatibility.resolve(recipe).toolchain.target
        let tree = workspace.appendingPathComponent(target, isDirectory: true)
        try write("<manifest package=\"\(recipe.package)\"/>", tree.appendingPathComponent("AndroidManifest.xml"))
        try write("versionInfo:\n  versionCode: 203\n", tree.appendingPathComponent("apktool.yml"))
        try write("ptbr", tree.appendingPathComponent("assets/global_localize_PTBR_P.pak"))

        XCTAssertThrowsError(try InstallationContent.prepared(toolchain: toolchain, recipe: recipe),
                             "The shared toolchain does not contain these generated target files.")
        let entries = try InstallationContent.prepared(toolchain: toolchain, recipe: recipe, metadataWorkspace: workspace)
        XCTAssertEqual(Set(entries.map(\.destination)), Set([
            "Documents/\(target)/AndroidManifest.xml",
            "Documents/\(target)/apktool.yml",
            "Documents/\(target)/assets/global_localize_PTBR_P.pak"
        ]))
        let canonicalWorkspace = workspace.resolvingSymlinksInPath().standardizedFileURL.path
        XCTAssertTrue(entries.allSatisfy { $0.source.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(canonicalWorkspace + "/") })

        recipe.files = []
        XCTAssertTrue(try InstallationContent.prepared(toolchain: toolchain, recipe: recipe, metadataWorkspace: workspace).isEmpty)
    }
    func testUnsignedBuildEnvironmentNeverPassesDeviceOrProvisioningOperations() {
        let environment = Toolchain.unsignedBuildEnvironment(["KLEPTON_DEVICE":"headset", "KLEPTON_SIM_UDID":"sim",
            "KLEPTON_TEAM":"TEAM000001", "KL_LX_GAME":"/fixture", "UNRELATED":"ignored"])
        XCTAssertNil(environment["KLEPTON_DEVICE"]); XCTAssertNil(environment["KLEPTON_SIM_UDID"])
        XCTAssertEqual(environment["KL_LX_GAME"],"/fixture")
        XCTAssertTrue(BuildOnlyPipeline.isSafe(BuildOnlyPipeline.compileCommand(project:URL(fileURLWithPath:"/fixture/Game.xcodeproj"), product:"Game",derivedData:URL(fileURLWithPath:"/fixture/derived"), environment:environment)))
    }

    func testTreeVerificationCatchesMissingFilesWithoutOverwritingMutableSaves() throws {
        let expected: [String: Int64] = ["assets/a":3, "save":10]
        let listing: (String) -> [RemoteFile] = { directory in
            directory.hasSuffix("assets") ? [RemoteFile(relativePath:"a",size:3,isDirectory:false)]
                : [RemoteFile(relativePath:"save",size:50,isDirectory:false)]
        }
        XCTAssertNoThrow(try InstallationContent.verifyTree(expected,directory:"Documents/game",allowModified:true,list:listing))
        XCTAssertThrowsError(try InstallationContent.verifyTree(expected,directory:"Documents/game",allowModified:false,list:listing))
        XCTAssertThrowsError(try InstallationContent.verifyTree(expected,directory:"Documents/game",allowModified:true) { _ in [] })
    }
    func testCompatibleProfileMayUseSecondExistingIdentity() throws {
        let (profile,identity) = ResumeReuseTests().profile()
        let result = try ExistingAppSigner.select(profiles:[profile],identities:[String(repeating:"0",count:40),identity],
            team:"TEAM000001",bundle:"test.game",device:"device",requested:[:],free:true)
        XCTAssertEqual(result.identity,identity)
    }
    func testProfileApprovalFailureRemainsResumableWithoutCompilingAgain() throws {
        let store = JobStore(directory:try scratch())
        let requestURL = URL(fileURLWithPath:"/fixture/request.json")
        var job = Job(recipe:try recipe(),request:InstallRequest(toolchain:"/fixture"),steps:[.build,.stage],toolchainCommit:"fixture")
        job.state = .failed; job.failureKind = .apple; job.failure = ProfileProvisioning.Required(request:requestURL).description
        try store.save(job)
        let resumed = try store.prepareResume(job.id)
        XCTAssertEqual(resumed.request.requireExistingBuildOnResume,true)
        XCTAssertEqual(resumed.remaining,[.build,.stage])
        XCTAssertFalse(ProfileProvisioning.userMessage(job.failure!).contains("PROFILE_REQUIRED"))
    }
    func testRemoteDateSupportsBothCoreDeviceFormats() throws {
        for date in ["2026-10-25T10:00:00Z","2026-10-25T10:00:00.000Z"] {
            let data = try JSONSerialization.data(withJSONObject:["result":["files":[["relativePath":"a","metadata":["size":3,"lastModDate":date],"resources":["isDirectory":false]]]]])
            XCTAssertNotNil(try DeviceControl.parseFiles(data).first?.modified)
        }
    }

    func testAllShippedRecipesResolveSafeDistinctDestinationsWithoutMutatingCatalog() throws {
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("recipes")
        let urls = try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).filter { $0.pathExtension == "json" }
        XCTAssertEqual(urls.count,48)
        for url in urls {
            let before = try Data(contentsOf:url), recipe = try JSONDecoder().decode(Recipe.self,from:before)
            let resolved = KleptonRecipeCompatibility.resolve(recipe)
            let paths = resolved.files.compactMap(StagePlan.destination)
            XCTAssertEqual(Set(paths).count,paths.count,recipe.id)
            XCTAssertTrue(paths.allSatisfy { $0.hasPrefix("Documents/") && !$0.contains("/../") },recipe.id)
            XCTAssertEqual(try Data(contentsOf:url),before)
        }
    }
    func testProfileSelectionRejectsWrongPlatformFutureAndChoosesLongestValidity() throws {
        let helper = ResumeReuseTests(), (profile,identity) = helper.profile()
        var later = profile; later.path = URL(fileURLWithPath:"/later"); later.values["ExpirationDate"] = Date().addingTimeInterval(7200)
        let plan = try ExistingAppSigner.plan(profiles:[profile,later],team:"TEAM000001",bundle:"test.game",device:"device",identity:identity,requested:[:],free:true)
        XCTAssertEqual(plan.profile,later.path)
        for field in ["Platform","CreationDate"] {
            var wrong = profile
            wrong.values[field] = field == "Platform" ? ["iOS"] as Any : Date().addingTimeInterval(1000) as Any
            XCTAssertThrowsError(try ExistingAppSigner.plan(profiles:[wrong],team:"TEAM000001",bundle:"test.game",device:"device",identity:identity,requested:[:],free:true))
        }
    }
    func testProfileRequestRequiresExplicitApprovalAndHandlesXcodeFailure() throws {
        let root = try scratch()
        let context = ProfileProvisioning(bundle:"test.game",team:"TEAM000001",device:"device",identity:String(repeating:"A",count:40),entitlements:Data("fixture".utf8))
        var calls = 0
        XCTAssertThrowsError(try context.openInXcode(approved:false,root:root) { _ in calls += 1 })
        XCTAssertEqual(calls,0); XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:root.path).isEmpty)
        XCTAssertThrowsError(try context.openInXcode(approved:true,root:root) { _ in calls += 1; throw DeviceError.tool("Xcode unavailable") })
        XCTAssertEqual(calls,1)
        let project = try context.openInXcode(approved:true,root:root) { _ in calls += 1 }
        let text = try String(contentsOf:project.appendingPathComponent("project.pbxproj"))
        XCTAssertNotNil(try PropertyListSerialization.propertyList(from:Data(text.utf8),format:nil) as? [String:Any])
        XCTAssertTrue(text.contains("CODE_SIGN_STYLE = Automatic")); XCTAssertTrue(text.contains(context.identity))
        XCTAssertFalse(text.contains("allowProvisioningUpdates"))
        let request = try context.save(under:root.appendingPathComponent("requests"))
        XCTAssertEqual(ProfileProvisioning.requestURL(in:ProfileProvisioning.Required(request:request).description),request)
    }
    func testPendingBuildSurvivesSigningFailureButRejectsChangedApp() throws {
        let root = try scratch(), app = root.appendingPathComponent("Game.app")
        try write("fixture",app.appendingPathComponent("Info.plist"))
        let artifact = ReusableBuild(app:app,workspace:root,sourceJobID:"fixture",bundleID:"test.game",files:try ReusableBuild.inventory(app))
        let receipt = root.appendingPathComponent("pending.json")
        try PendingBuild.save(artifact,key:"same inputs",at:receipt)
        XCTAssertNotNil(try PendingBuild.load(at:receipt,key:"same inputs"))
        XCTAssertNil(try PendingBuild.load(at:receipt,key:"changed inputs"))
        try write("tampered",app.appendingPathComponent("Info.plist"))
        XCTAssertThrowsError(try PendingBuild.load(at:receipt,key:"same inputs"))
    }
    func testJobCannotFinishWhenStageVerificationFailsAndResumeKeepsBuild() async throws {
        let store = JobStore(directory:try scratch())
        var job = Job(recipe:try recipe(),request:InstallRequest(toolchain:try Verified850Fixture.source().root.path),steps:[.build,.stage],toolchainCommit:"cc2856c")
        job.completed = [.build]; try store.save(job)
        do {
            _ = try await JobRunner(store:store).run(job,currentToolchain:"cc2856c") { _,_ in throw DeviceError.tool("missing metadata") }
            XCTFail("Incomplete install must fail")
        } catch { }
        let failed = try store.load(job.id)
        XCTAssertEqual(failed.state,.failed); XCTAssertEqual(failed.completed,[.build])
        let resumed = try store.prepareResume(job.id)
        let called = LockedBox<[InstallStep]>([])
        _ = try await JobRunner(store:store).run(resumed,currentToolchain:"cc2856c") { step,_ in called.update { $0.append(step) } }
        XCTAssertEqual(called.get(),[.stage])
    }
}
