import XCTest
@testable import AVPPlayCore

/// All queries and transfers are simulated; no headset, game build or real Job is used.
final class StageResume151Tests: XCTestCase {
    let device = Device(udid: "fixture-device", name: "Fixture", osVersion: "27", reachable: true,
                        paired: true, developerMode: true)
    let bundle = "test.zero-caliber"
    let folder = "Documents/android-files/Android/obb/com.XrealGames.Zc15"
    let metadata = "Documents/x6072194326150034/AndroidManifest.xml"

    func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stage151-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    static func json(_ files: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["info": ["outcome": "success"], "result": ["files": files]])
    }
    static func file(_ name: String, directory: Bool = false) -> [String: Any] {
        ["relativePath": name, "resources": ["isDirectory": directory], "metadata": ["size": 3]]
    }
    func failure(_ error: Error) throws -> RemoteQueryFailure {
        guard case DeviceError.fileQuery(let failure) = error else { throw error }
        return failure
    }

    func testDisconnectTimeoutUnavailableAndStreamingActionNeverBecomeEmpty() throws {
        for (text, kind) in [("socket was closed unexpectedly", RemoteQueryFailure.Kind.communication),
                             ("Operation timed out", .communication),
                             ("device disconnected immediately after connecting", .unavailable),
                             ("Failed to allocate RSD device", .unavailable),
                             ("StreamingAction: failed to get a list of files", .communication)] {
            let control = DeviceControl(query: { _ in throw DeviceError.tool(text) })
            XCTAssertThrowsError(try control.files(device: device, bundle: bundle, subdirectory: folder)) { error in
                do {
                    let failure = try self.failure(error)
                    XCTAssertEqual(failure.kind, kind)
                    XCTAssertEqual(failure.path, self.folder)
                    XCTAssertTrue(failure.operation.contains("device info files"))
                    XCTAssertEqual(FailureKind.of(error), .device)
                } catch { XCTFail("\(error)") }
            }
        }
    }
    func testSuccessfulEmptyDirectoryIsExplicitlyPresent() throws {
        let control = DeviceControl(query: { _ in try Self.json([]) })
        XCTAssertEqual(try control.listing(device: device, bundle: bundle, subdirectory: folder), .present([]))
    }
    func testMissingDirectoryRequiresSuccessfulParentEvidence() throws {
        let control = DeviceControl(query: { args in
            let path = args[try XCTUnwrap(args.firstIndex(of: "--subdirectory")) + 1]
            if path == "Documents/missing" { throw DeviceError.tool("No such file or directory") }
            return try Self.json([Self.file("other", directory: true)])
        })
        XCTAssertEqual(try control.listing(device: device, bundle: bundle, subdirectory: "Documents/missing"), .missingDirectory)
    }
    func testMissingTextWithFailedOrContradictoryParentRemainsInconclusive() throws {
        for offline in [false, true] {
            let control = DeviceControl(query: { args in
                let path = args[try XCTUnwrap(args.firstIndex(of: "--subdirectory")) + 1]
                if path == "Documents/exists" { throw DeviceError.tool("No such file or directory") }
                if offline { throw DeviceError.tool("Operation timed out") }
                return try Self.json([Self.file("exists", directory: true)])
            })
            XCTAssertThrowsError(try control.checkedFiles(device: device, bundle: bundle, subdirectory: "Documents/exists"))
        }
    }
    func testNestedMissingDirectoryConfirmedByExistingAncestor() throws {
        let control = DeviceControl(query: { args in
            let path = args[try XCTUnwrap(args.firstIndex(of: "--subdirectory")) + 1]
            if path == "Documents" { return try Self.json([]) }
            throw DeviceError.tool("NSCocoaErrorDomain Code=260")
        })
        XCTAssertEqual(try control.listing(device: device, bundle: bundle, subdirectory: "Documents/missing/nested"), .missingDirectory)
    }
    func testMalformedPartialDuplicateAndFailedOutcomeAreNotEmptyListings() throws {
        let malformed: [Data] = [Data("{}".utf8), Data("not JSON".utf8),
            try Self.json([["relativePath": "a"]]),
            try Self.json([Self.file("a"), Self.file("a")]),
            try Self.json([Self.file("../escape")]),
            Data(#"{"info":{"outcome":"failure"},"result":{"files":[]}}"#.utf8)]
        for data in malformed {
            let control = DeviceControl(query: { _ in data })
            XCTAssertThrowsError(try control.files(device: device, bundle: bundle, subdirectory: folder))
        }
        let control = DeviceControl(query: { _ in try Self.json([Self.file("nested/file")]) })
        XCTAssertThrowsError(try control.checkedFiles(device: device, bundle: bundle, subdirectory: folder))
    }

    struct Fixture {
        let entries: [InstallationContent.Entry]
        let receipt: URL
        let scope: URL
        let known: [String: InstallationContent.Receipt]
    }
    func fixture(_ root: URL) throws -> Fixture {
        let sizes: [Int64] = [4180498542, 3689150068, 3757446309, 3959978364, 751992937, 3726201092]
        let names = ["main", "overflow1", "overflow2", "overflow3", "overflow4", "patch"]
        let entries = zip(names, sizes).enumerated().map { index, item in
            InstallationContent.Entry(source: root.appendingPathComponent(item.0),
                destination: "\(folder)/\(item.0).1173.com.XrealGames.Zc15.obb", size: item.1,
                sha256: String(repeating: String(index + 1), count: 64))
        }
        let known = Dictionary(uniqueKeysWithValues: entries.map {
            ($0.destination, InstallationContent.Receipt(digest: $0.sha256, size: $0.size, modified: Date(timeIntervalSince1970: 100)))
        })
        let receipt = root.appendingPathComponent(".stage-verification.json")
        let scope = root.appendingPathComponent(".stage-container.json")
        try JSONEncoder().encode(known).write(to: receipt)
        try "\(device.udid)|\(bundle)|file:///fixture/Game.app/".write(to: scope, atomically: true, encoding: .utf8)
        XCTAssertEqual(entries.reduce(0) { $0 + $1.size }, 20_065_267_312)
        return Fixture(entries: entries, receipt: receipt, scope: scope, known: known)
    }
    func stat(_ fixture: Fixture, _ path: String) -> RemoteFile? {
        fixture.known[path].map { RemoteFile(relativePath: (path as NSString).lastPathComponent, size: $0.size,
                                            isDirectory: false, modified: $0.modified) }
    }
    func testSixValidReceiptsRequireLiveStatsAndUploadNothing() throws {
        let fixture = try fixture(scratch()), before = try Data(contentsOf: fixture.receipt)
        var queries: [String] = []
        try InstallationContent.sync(fixture.entries, container: .init(stat: { path in
            queries.append(path); return self.stat(fixture, path)
        }, fetch: { _, _ in XCTFail("Unchanged OBB must not be downloaded again") },
           put: { _, _ in XCTFail("Unchanged OBB must not be uploaded") }), receipts: fixture.receipt)
        XCTAssertEqual(Set(queries), Set(fixture.entries.map(\.destination)))
        XCTAssertEqual(try Data(contentsOf: fixture.receipt), before, "preserve receipt bytes on verification-only resume")
    }
    func testReceiptsAloneCannotBypassUnavailableRemote() throws {
        let fixture = try fixture(scratch()), before = try Data(contentsOf: fixture.receipt)
        XCTAssertThrowsError(try InstallationContent.sync(fixture.entries, container: .init(
            stat: { _ in throw DeviceError.tool("Operation timed out") },
            fetch: { _, _ in XCTFail("No readback") }, put: { _, _ in XCTFail("No upload") }), receipts: fixture.receipt))
        XCTAssertEqual(try Data(contentsOf: fixture.receipt), before)
    }
    func testFinalMetadataListingFailurePreventsEvenEarlierMissingOBBCopy() throws {
        let root = try scratch(), fixture = try fixture(root), before = try Data(contentsOf: fixture.receipt)
        let meta = InstallationContent.Entry(source: root.appendingPathComponent("manifest"), destination: metadata,
                                             size: 8988, sha256: String(repeating: "a", count: 64))
        var logs: [String] = []
        XCTAssertThrowsError(try InstallationContent.sync(fixture.entries + [meta], container: .init(
            stat: { path in
                if path == self.metadata { throw DeviceError.tool("CoreDevice.ActionError error 3: StreamingAction failed to get a list of files") }
                return nil // Even a missing OBB cannot be uploaded before the metadata query succeeds.
            }, fetch: { _, _ in XCTFail("No readback") }, put: { _, _ in XCTFail("No upload") }),
            receipts: fixture.receipt, report: { logs.append($0) })) { error in
                XCTAssertTrue("\(error)".contains(self.metadata))
                XCTAssertTrue("\(error)".contains("StreamingAction"))
            }
        XCTAssertTrue(logs.contains { $0.contains(metadata) })
        XCTAssertEqual(try Data(contentsOf: fixture.receipt), before)
    }
    func testOnlyMissingMetadataIsRepairedAndSecondResumeIsIdempotent() throws {
        let root = try scratch(), fixture = try fixture(root)
        let source = root.appendingPathComponent("manifest"); try Data("metadata".utf8).write(to: source)
        let meta = try InstallationContent.entry(source: source, destination: metadata)
        var uploaded: [String] = [], remoteMeta: RemoteFile?
        let container = InstallationContent.Container(stat: { path in
            path == self.metadata ? remoteMeta : self.stat(fixture, path)
        }, fetch: { path, url in
            XCTAssertEqual(path, self.metadata, "Only pending metadata can require readback")
            try Data(contentsOf: source).write(to: url)
        }, put: { _, path in
            uploaded.append(path)
            remoteMeta = RemoteFile(relativePath: "AndroidManifest.xml", size: meta.size, isDirectory: false,
                                    modified: Date(timeIntervalSince1970: 200))
        })
        try InstallationContent.sync(fixture.entries + [meta], container: container, receipts: fixture.receipt)
        let after = try InstallationContent.loadReceipts(fixture.receipt)
        for (key, value) in fixture.known { XCTAssertEqual(after[key], value) }
        XCTAssertEqual(uploaded, [metadata])
        try InstallationContent.sync(fixture.entries + [meta], container: container, receipts: fixture.receipt)
        XCTAssertEqual(uploaded, [metadata])
    }
    func testSuccessfulEmptyDirectoryStillDetectsRealMissingFile() throws {
        let root = try scratch(), source = root.appendingPathComponent("manifest")
        try Data("metadata".utf8).write(to: source)
        let entry = try InstallationContent.entry(source: source, destination: metadata)
        let control = DeviceControl(query: { _ in try Self.json([]) })
        let plan = try InstallationContent.preflight([entry], stat: { path in
            try control.checkedFiles(device: self.device, bundle: self.bundle,
                subdirectory: (path as NSString).deletingLastPathComponent).first { $0.relativePath == "AndroidManifest.xml" }
        })
        XCTAssertNil(plan[metadata])
    }
    func testChangedOrMissingRemoteDateForcesReadbackWithoutBlindUpload() throws {
        for date in [nil, Date(timeIntervalSince1970: 101)] as [Date?] {
            let root = try scratch(), fixture = try fixture(root)
            let source = root.appendingPathComponent("small"); try Data("same".utf8).write(to: source)
            let entry = try InstallationContent.entry(source: source, destination: fixture.entries[0].destination)
            var reads = 0
            try InstallationContent.sync([entry], container: .init(stat: { _ in
                RemoteFile(relativePath: "main.obb", size: entry.size, isDirectory: false, modified: date)
            }, fetch: { _, url in reads += 1; try Data("same".utf8).write(to: url) },
               put: { _, _ in XCTFail("Same bytes must not be uploaded") }), receipts: fixture.receipt)
            XCTAssertEqual(reads, 1)
        }
    }
    func testWrongContainerBundleDeviceOrUnknownInstallationCannotUseOrEraseReceipts() throws {
        let fixture = try fixture(scratch()), before = try Data(contentsOf: fixture.receipt)
        let app = InstalledApp(bundleIdentifier: bundle, name: "Fixture", version: nil, bundleVersion: nil, url: "file:///fixture/Game.app/")
        XCTAssertNoThrow(try InstallationContent.installationScope(device: device, bundle: bundle, apps: [app], scopeFile: fixture.scope, receipts: fixture.receipt))
        var other = app; other.url = "file:///fixture/NewInstall.app/"
        for apps in [[], [other], [app, app], [InstalledApp(bundleIdentifier: "wrong", name: "Other", version: nil, bundleVersion: nil)]] {
            XCTAssertThrowsError(try InstallationContent.installationScope(device: device, bundle: bundle, apps: apps, scopeFile: fixture.scope, receipts: fixture.receipt))
        }
        let wrongDevice = Device(udid: "other", name: "Other", osVersion: "27", reachable: true, paired: true, developerMode: true)
        XCTAssertThrowsError(try InstallationContent.installationScope(device: wrongDevice, bundle: bundle, apps: [app], scopeFile: fixture.scope, receipts: fixture.receipt))
        XCTAssertThrowsError(try InstallationContent.installationScope(device: device, bundle: "wrong", apps: [app], scopeFile: fixture.scope, receipts: fixture.receipt))
        XCTAssertEqual(try Data(contentsOf: fixture.receipt), before)
    }
    func testCorruptReceiptsAreNotReset() throws {
        let fixture = try fixture(scratch()), corrupt = Data("{broken".utf8)
        try corrupt.write(to: fixture.receipt)
        XCTAssertThrowsError(try InstallationContent.sync(fixture.entries, container: .init(
            stat: { _ in XCTFail("Do not query with unreadable receipts"); return nil },
            fetch: { _, _ in XCTFail() }, put: { _, _ in XCTFail() }), receipts: fixture.receipt))
        XCTAssertEqual(try Data(contentsOf: fixture.receipt), corrupt)
    }
    func testLateFinalStatFailurePreservesSixReceiptsByteForByte() throws {
        let root = try scratch(), fixture = try fixture(root), before = try Data(contentsOf: fixture.receipt)
        let source = root.appendingPathComponent("manifest"); try Data("metadata".utf8).write(to: source)
        let meta = try InstallationContent.entry(source: source, destination: metadata)
        var queries = 0
        XCTAssertThrowsError(try InstallationContent.sync(fixture.entries + [meta], container: .init(stat: { path in
            if path == self.metadata {
                queries += 1
                if queries > 1 { throw DeviceError.tool("StreamingAction failed to get a list of files") }
                return RemoteFile(relativePath: "AndroidManifest.xml", size: meta.size, isDirectory: false)
            }
            return self.stat(fixture, path)
        }, fetch: { _, _ in XCTFail("Failure occurs before metadata readback") },
           put: { _, _ in XCTFail("No upload") }), receipts: fixture.receipt)) { error in
            XCTAssertTrue("\(error)".contains(self.metadata))
        }
        XCTAssertEqual(queries, 2)
        XCTAssertEqual(try Data(contentsOf: fixture.receipt), before)
    }
    func testDirectoryAtRequiredFilePathBlocksTransfer() throws {
        let fixture = try fixture(scratch())
        XCTAssertThrowsError(try InstallationContent.sync(fixture.entries, container: .init(stat: { _ in
            RemoteFile(relativePath: "main.obb", size: 0, isDirectory: true)
        }, fetch: { _, _ in XCTFail() }, put: { _, _ in XCTFail() }), receipts: fixture.receipt))
    }
    func testIdentityFailureBeforeCopyIsNotRetriedAsAnUpload() throws {
        let root = try scratch()
        let installer = Installer(recipe: try ResumeReuseTests().recipe(), request: InstallRequest(toolchain: "/fixture"),
                                  store: ContentStore(root: root), report: { _ in })
        var validations = 0
        XCTAssertThrowsError(try installer.copyWithRetry(StageItem(source: root.appendingPathComponent("source"),
            destination: metadata, size: 8), to: device, bundle: bundle, beforeCopy: {
                validations += 1
                throw DeviceError.tool("Identity unavailable")
            }))
        XCTAssertEqual(validations, 1)
    }
    func testTruncatedOBBWithOldReceiptRepairsOnlyThatOBB() throws {
        let root = try scratch(), fixture = try fixture(root)
        let source = root.appendingPathComponent("main"); try Data("correct".utf8).write(to: source)
        let main = try InstallationContent.entry(source: source, destination: fixture.entries[0].destination)
        var known = fixture.known
        known[main.destination] = .init(digest: main.sha256, size: main.size, modified: Date(timeIntervalSince1970: 100))
        try JSONEncoder().encode(known).write(to: fixture.receipt)
        var mainStat = RemoteFile(relativePath: "main.obb", size: 3, isDirectory: false,
                                  modified: Date(timeIntervalSince1970: 200))
        var uploads: [String] = []
        try InstallationContent.sync([main] + Array(fixture.entries.dropFirst()), container: .init(stat: { path in
            path == main.destination ? mainStat : self.stat(fixture, path)
        }, fetch: { path, url in
            XCTAssertEqual(path, main.destination)
            try Data("correct".utf8).write(to: url)
        }, put: { _, path in
            XCTAssertEqual(path, main.destination)
            uploads.append(path)
            mainStat = RemoteFile(relativePath: "main.obb", size: main.size, isDirectory: false,
                                  modified: Date(timeIntervalSince1970: 300))
        }), receipts: fixture.receipt)
        XCTAssertEqual(uploads, [main.destination])
        let after = try InstallationContent.loadReceipts(fixture.receipt)
        for entry in fixture.entries.dropFirst() { XCTAssertEqual(after[entry.destination], known[entry.destination]) }
    }
    func testFailedFinalVerificationKeepsJobBuildAndResumesOnlyStage() async throws {
        let root = try scratch(), store = JobStore(directory: root)
        var job = Job(recipe: try ResumeReuseTests().recipe(), request: InstallRequest(toolchain: try Verified850Fixture.source().root.path),
                      steps: [.fetch, .build, .stage], toolchainCommit: "cc2856c")
        job.completed = [.fetch, .build]; job.state = .running; job.attempts = 3
        try store.save(job)
        do {
            _ = try await JobRunner(store: store).run(job, currentToolchain: "cc2856c") { _, _ in
                throw DeviceError.fileQuery(RemoteQueryFailure(operation: "stat", device: "fixture", bundle: self.bundle,
                    path: self.metadata, underlying: DeviceError.tool("StreamingAction")))
            }
            XCTFail("Must not finish")
        } catch { }
        let failed = try store.load(job.id)
        XCTAssertEqual(failed.completed, [.fetch, .build]); XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(failed.failureKind, .device)
        let resumed = try store.prepareResume(job.id)
        XCTAssertEqual(resumed.remaining, [.stage])
        let finished = try await JobRunner(store: store).run(resumed, currentToolchain: "cc2856c") { step, _ in
            XCTAssertEqual(step, .stage)
        }
        XCTAssertEqual(finished.state, .finished)
    }
}
