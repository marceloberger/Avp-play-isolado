import XCTest
@testable import AVPPlayCore

final class AutomaticLocalInstallTests: XCTestCase {
    let source = "fixture.team.dev.klepton.target.re4"
    let original = "fixture.dev.klepton.target.re4"
    func fixture() throws -> (URL, JobStore, Job, LocalAPKVariant, Toolchain, LocalBuildReceipt) {
        let helper = ResumeReuseTests(), root = try helper.scratch(), recipe = try helper.recipe()
        let f = try Verified850Fixture.build(root: root, recipe: recipe, bundle: source, room: false)
        // Preserve JobStore's exact encoding; the receipt binds original bytes, not a re-encoding.
        let receipt = try LocalBuildReceipt(jobData: Data(contentsOf: f.jobs.url(f.job.id)),
            logData: Data(contentsOf: f.jobs.directory.appendingPathComponent(f.job.id + ".log")),
            artifact: f.artifact, variant: f.variant)
        // This fixture starts with a deliberately missing SYNTHETIC Job; no user data is referenced.
        XCTAssertTrue(f.jobs.directory.path.hasPrefix(root.path + "/"))
        try FileManager.default.removeItem(at: f.jobs.url(f.job.id))
        try FileManager.default.removeItem(at: f.jobs.directory.appendingPathComponent(f.job.id + ".log"))
        return (root, f.jobs, f.job, f.variant, f.runtime, receipt)
    }

    func testMissingJobRecoversExactBytesWithoutAccessingNonexistentAPKOrOBBs() throws {
        let (root,jobs,job,variant,tc,receipt) = try fixture()
        let recovery = LocalBuildRecovery(workspaceRoot: root.appendingPathComponent("build-only"))
        try recovery.save(receipt)
        let found = try XCTUnwrap(recovery.artifact(jobs: jobs, recipe: job.recipe, variant: variant, toolchain: tc, report: { print($0) }))
        XCTAssertEqual(found.0, receipt.artifact)
        XCTAssertEqual(try Data(contentsOf: jobs.directory.appendingPathComponent(job.id + ".json")),receipt.jobData)
        XCTAssertEqual(try Data(contentsOf: jobs.directory.appendingPathComponent(job.id + ".log")),receipt.logData)
        XCTAssertEqual(try ReusableBuild.inventory(receipt.artifact.app),receipt.artifact.files)
        XCTAssertNotNil(try recovery.artifact(jobs: jobs, recipe: job.recipe, variant: variant, toolchain: tc))
    }
    func testChangedNativeBytesRejectRecoveryBeforeRestoringJob() throws {
        let (root,jobs,job,variant,tc,receipt) = try fixture()
        let recovery = LocalBuildRecovery(workspaceRoot: root.appendingPathComponent("build-only")); try recovery.save(receipt)
        try Data("corrupt".utf8).write(to: receipt.artifact.app.appendingPathComponent("Fixture"))
        XCTAssertThrowsError(try recovery.artifact(jobs: jobs, recipe: job.recipe, variant: variant, toolchain: tc))
        XCTAssertFalse(FileManager.default.fileExists(atPath: jobs.directory.appendingPathComponent(job.id + ".json").path))
    }
    func testRecipeMismatchAndMissingEvidenceBlockInsteadOfCompiling() throws {
        let (root,jobs,job,variant,tc,receipt) = try fixture()
        let recovery = LocalBuildRecovery(workspaceRoot: root.appendingPathComponent("build-only"))
        XCTAssertThrowsError(try recovery.artifact(jobs: jobs, recipe: job.recipe, variant: variant, toolchain: tc))
        try recovery.save(receipt)
        var changed = job.recipe; changed.title += "changed"
        XCTAssertThrowsError(try recovery.artifact(jobs: jobs, recipe: changed, variant: variant, toolchain: tc))
        XCTAssertTrue(jobs.all().isEmpty)
    }
    func testExistingHistoryCollisionIsNeverOverwritten() throws {
        let (root,jobs,job,variant,tc,receipt) = try fixture()
        let recovery = LocalBuildRecovery(workspaceRoot: root.appendingPathComponent("build-only"));try recovery.save(receipt)
        try FileManager.default.createDirectory(at: jobs.directory, withIntermediateDirectories: true)
        let path = jobs.directory.appendingPathComponent(job.id + ".log"), original = Data("unrelated history".utf8)
        try original.write(to: path)
        XCTAssertThrowsError(try recovery.artifact(jobs: jobs, recipe: job.recipe, variant: variant, toolchain: tc))
        XCTAssertEqual(try Data(contentsOf: path),original)
        XCTAssertTrue(jobs.all().isEmpty)
    }
    func testFailedJobCannotBecomeSuccessReceipt() throws {
        let (_,_,job,_,_,receipt) = try fixture(); var failed = job;failed.state = .failed
        let enc = JSONEncoder();enc.dateEncodingStrategy = .iso8601
        XCTAssertThrowsError(try LocalBuildReceipt(jobData: enc.encode(failed),logData:receipt.logData,artifact:receipt.artifact))
    }
    func testAutomaticIdentitySelectsInstalledIDAndStagesSelectedData() throws {
        let (_,_,job,_,_,receipt) = try fixture()
        let (fixture,identity) = ResumeReuseTests().profile()
        var profile = fixture;profile.values["Entitlements"] = ["application-identifier":"TEAM000001."+original,
            "keychain-access-groups":["TEAM000001.*"],"get-task-allow":true,"com.apple.developer.kernel.increased-memory-limit":true]
        let device = Device(udid:"device",name:"Fixture",osVersion:"27",reachable:true,paired:true,developerMode:true)
        let app = InstalledApp(bundleIdentifier:original,name:"Fixture",version:"1",bundleVersion:"1",url:"file:///old.app")
        let plan = try AutomaticLocalInstall.plan(artifact:receipt.artifact,job:job,recipe:job.recipe,device:device,team:"TEAM000001",apps:[app],profiles:[profile],identities:[identity],free:true)
        XCTAssertEqual(plan.request.bundleId,original);XCTAssertEqual(plan.request.preservedBuildBundleID,source)
        XCTAssertEqual(plan.request.reuseBuildOnly,true);XCTAssertEqual(plan.request.resign,true)
        XCTAssertEqual(plan.steps,InstallStep.localAPKInstall);XCTAssertEqual(plan.request.roomMeasuring,false)
        XCTAssertNil(plan.request.replacementConsent)
        let clean = try AutomaticLocalInstall.plan(artifact:receipt.artifact,job:job,recipe:job.recipe,device:device,team:"TEAM000001",apps:[],profiles:[profile],identities:[identity],free:true)
        XCTAssertEqual(clean.request.bundleId,original);XCTAssertEqual(clean.steps,InstallStep.localAPKInstall)
        XCTAssertThrowsError(try AutomaticLocalInstall.plan(artifact:receipt.artifact,job:job,recipe:job.recipe,device:device,team:"TEAM000001",apps:[app,app],profiles:[profile],identities:[identity],free:true))
        XCTAssertThrowsError(try AutomaticLocalInstall.plan(artifact:receipt.artifact,job:job,recipe:job.recipe,device:device,team:"TEAM000001",apps:[app],profiles:[],identities:[identity],free:true))
    }
    func testAutomaticReuseCannotSwitchAwayFromBuildTeam() throws {
        let (_,_,job,_,_,receipt) = try fixture()
        var built = job; built.request.team = "BB7G7A8FSP"
        let device = Device(udid:"device",name:"Fixture",osVersion:"27",reachable:true,paired:true,developerMode:true)
        XCTAssertThrowsError(try AutomaticLocalInstall.plan(artifact:receipt.artifact,job:built,recipe:built.recipe,
            device:device,team:"E6B6898BEU",apps:[],profiles:[],identities:[],free:false)) { error in
            XCTAssertTrue("\(error)".contains("BB7G7A8FSP"))
            XCTAssertTrue("\(error)".contains("não será usada automaticamente"))
        }
    }
    func testReplacementNeedsMatchingConsentAndDetectsDeviceOrInstallChanges() throws {
        let app = InstalledApp(bundleIdentifier:original,name:"Fixture",version:"1",bundleVersion:"1",url:"file:///old.app")
        let consent = LocalReplacementConsent(device:"device",app:app)
        XCTAssertThrowsError(try LocalReplacementConsent.requireCurrent(apps:[app],device:"device",bundle:original,consent:nil))
        XCTAssertNoThrow(try LocalReplacementConsent.requireCurrent(apps:[app],device:"device",bundle:original,consent:consent))
        XCTAssertThrowsError(try LocalReplacementConsent.requireCurrent(apps:[app],device:"other",bundle:original,consent:consent))
        var changed=app;changed.url="file:///changed.app"
        XCTAssertThrowsError(try LocalReplacementConsent.requireCurrent(apps:[changed],device:"device",bundle:original,consent:consent))
        XCTAssertThrowsError(try LocalReplacementConsent.requireCurrent(apps:[],device:"device",bundle:original,consent:consent))
        XCTAssertNoThrow(try LocalReplacementConsent.requireCurrent(apps:[],device:"device",bundle:original,consent:nil))
    }
}
