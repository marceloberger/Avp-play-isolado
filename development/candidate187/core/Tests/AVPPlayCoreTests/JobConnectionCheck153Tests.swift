import XCTest
@testable import AVPPlayCore

final class JobConnectionProbe153Tests: XCTestCase {
    let device = Device(udid: "hardware-udid", name: "Fixture", osVersion: "27", reachable: true,
                        paired: true, developerMode: true, connected: true, coreDeviceIdentifier: "core-device-uuid")
    let bundle = "test.zero-caliber"
    let streaming = "CoreDevice.ActionError error 3: StreamingAction failed to get a list of files"
    func devices(connected: Bool = true) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["result": ["devices": [["identifier": "core-device-uuid",
            "hardwareProperties": ["platform": "visionOS", "reality": "physical", "udid": "hardware-udid"],
            "connectionProperties": ["pairingState": "paired", "state": connected ? "connected" : "disconnected"],
            "deviceProperties": ["developerModeStatus": "enabled"]]]]])
    }
    func fixture() throws -> (Job, ContentStore) {
        let recipe = try CommunityAPKStage152Tests().frozenRecipe()
        var request = InstallRequest(toolchain: "/fixture"); request.device = device.udid; request.bundleId = bundle
        var job = Job(recipe: recipe, request: request, steps: [.fetch, .build, .stage], toolchainCommit: "fixture")
        job.completed = [.fetch, .build]; job.state = .failed
        return (job, ContentStore(root: try StageResume151Tests().scratch()))
    }
    func testConnectedConfirmsIdentityListsMetadataAndNeverTransfers() throws {
        let (job, store) = try fixture()
        var queries: [[String]] = []
        let control = DeviceControl(query: { args in
            queries.append(args)
            if args == ["list", "devices"] { return try self.devices() }
            if args.contains("apps") { return try CoreDeviceIdentity152Tests.response([CoreDeviceIdentity152Tests.app()]) }
            XCTAssertTrue(args.contains("files")); XCTAssertFalse(args.contains("copy"))
            let path = args[args.firstIndex(of: "--subdirectory")! + 1]
            let names = path == "Documents" ? ["x6072194326150034.apk"] : ["AndroidManifest.xml", "apktool.yml"]
            return try StageResume151Tests.json(names.map { StageResume151Tests.file($0) })
        })
        let message = try JobConnectionCheck.run(job: job, store: store, control: control)
        XCTAssertTrue(message.contains("identidade da instalação confirmada")); XCTAssertTrue(message.contains("Stage continua pendente"))
        XCTAssertFalse(message.contains("Ausência confirmada")); XCTAssertEqual(queries.filter { $0.contains("apps") }.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory(for: job.recipe).path))
    }
    func testDisconnectedStopsBeforeAppOrFileQuery() throws {
        let (job, store) = try fixture()
        let control = DeviceControl(query: { args in XCTAssertEqual(args, ["list", "devices"]); return try self.devices(connected: false) })
        XCTAssertThrowsError(try JobConnectionCheck.run(job: job, store: store, control: control))
    }
    func testStreamingFailureWithAbsentParentEntryConfirmsMissingDirectory() throws {
        let control = DeviceControl(query: { args in
            let path = args[args.firstIndex(of: "--subdirectory")! + 1]
            if path == "Documents/missing" { throw DeviceError.tool(self.streaming) }
            XCTAssertEqual(path, "Documents")
            return try StageResume151Tests.json([StageResume151Tests.file("other", directory: true)])
        })
        XCTAssertEqual(try control.listing(device: device, bundle: bundle, subdirectory: "Documents/missing"), .missingDirectory)
    }
    func testStreamingFailureWithPresentParentEntryRemainsFailure() throws {
        let control = DeviceControl(query: { args in
            let path = args[args.firstIndex(of: "--subdirectory")! + 1]
            if path == "Documents/exists" { throw DeviceError.tool(self.streaming) }
            return try StageResume151Tests.json([StageResume151Tests.file("exists", directory: true)])
        })
        XCTAssertThrowsError(try control.listing(device: device, bundle: bundle, subdirectory: "Documents/exists"))
    }
    func testStreamingFailureWithFailedParentCannotProveAbsence() throws {
        let control = DeviceControl(query: { _ in throw DeviceError.tool(self.streaming) })
        XCTAssertThrowsError(try control.listing(device: device, bundle: bundle, subdirectory: "Documents/missing"))
    }
    func testMalformedParentCannotProveAbsence() throws {
        let control = DeviceControl(query: { args in
            if args.contains("Documents/missing") { throw DeviceError.tool(self.streaming) }
            return Data("{}".utf8)
        })
        XCTAssertThrowsError(try control.listing(device: device, bundle: bundle, subdirectory: "Documents/missing"))
    }
    func testNoStageRequiresOnlyDeviceAndDoesNotMarkJobFinished() throws {
        var (job, store) = try fixture(); job.steps = [.fetch]
        let control = DeviceControl(query: { args in XCTAssertEqual(args, ["list", "devices"]); return try self.devices() })
        XCTAssertTrue(try JobConnectionCheck.run(job: job, store: store, control: control).contains("conectado"))
        XCTAssertEqual(job.state, .failed)
    }
    func testActualMissingTreeAndAPKAreReportedAfterSuccessfulRootListing() throws {
        let (job, store) = try fixture()
        let control = DeviceControl(query: { args in
            if args == ["list", "devices"] { return try self.devices() }
            if args.contains("apps") { return try CoreDeviceIdentity152Tests.response([CoreDeviceIdentity152Tests.app()]) }
            if args.contains("Documents") { return try StageResume151Tests.json([StageResume151Tests.file("android-files", directory: true)]) }
            throw DeviceError.tool(self.streaming)
        })
        let result = try JobConnectionCheck.run(job: job, store: store, control: control)
        XCTAssertTrue(result.contains("Ausência confirmada por listagem")); XCTAssertTrue(result.contains("Documents/x6072194326150034.apk"))
        XCTAssertTrue(result.contains("AndroidManifest.xml")); XCTAssertTrue(result.contains("apktool.yml"))
    }
}
