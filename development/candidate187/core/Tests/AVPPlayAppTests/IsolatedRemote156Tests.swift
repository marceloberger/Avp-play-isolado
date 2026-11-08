import XCTest
@testable import AVPPlayApp
@testable import AVPPlayCore

final class IsolatedRemote156Tests: XCTestCase {
    @MainActor
    func testRemoteCannotMutateJobsOrSettingsWithoutLocalAuthorization() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("remote156-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at:root) }
        let paths=Paths(recipes:nil,store:ContentStore(root:root.appendingPathComponent("store")),
                        jobs:JobStore(directory:root.appendingPathComponent("jobs")),
                        packager:ToolchainPackager(root:root.appendingPathComponent("toolchains")))
        let model=AppModel(paths:paths,runJobsAutomatically:false,resumeDevices:{XCTFail("No device query");return []})
        let before=model.surrealSupport
        XCTAssertNotNil(model.performIsolatedRemote(.clearJobs(kind:"all")))
        XCTAssertNotNil(model.performIsolatedRemote(.updateAll))
        XCTAssertNotNil(model.performIsolatedRemote(.panelAction(panel:"settings",item:"surrealSupport",value:before ? "0":"1"),confirmation:{_ in false}))
        XCTAssertEqual(model.surrealSupport,before)
        XCTAssertTrue(paths.jobs.all().isEmpty);XCTAssertNil(model.runningJob)
        XCTAssertTrue(model.remoteStatus().jobs.isEmpty)
        XCTAssertTrue(model.remoteLibrary().games.isEmpty)
    }

    func testRemoteBuildPlanCannotCreateProvisioningOrInstall() throws {
        let command=try IsolatedRemoteBuild.command(source:URL(fileURLWithPath:"/fixture/source"),
            output:URL(fileURLWithPath:"/fixture/output"),team:"TESTTEAM00")
        XCTAssertTrue(BuildOnlyPipeline.isSafe(command))
        XCTAssertTrue(command.arguments.contains("CODE_SIGNING_ALLOWED=NO"))
        XCTAssertFalse(command.arguments.contains("-allowProvisioningUpdates"))
        XCTAssertTrue(command.arguments.contains("PRODUCT_BUNDLE_IDENTIFIER=io.github.mymartek.avpplay.modified.candidate187.remote"))
        XCTAssertNotEqual(RemoteWire.serviceType,"_avpplay._tcp")
        XCTAssertEqual(RemoteWire.defaultPort,47988);XCTAssertEqual(RemoteWire.pairPort,47989)
    }
}
