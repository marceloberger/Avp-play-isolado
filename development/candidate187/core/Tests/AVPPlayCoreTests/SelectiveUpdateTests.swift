import XCTest
@testable import AVPPlayCore

final class SelectiveUpdateTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("avpplay-selective-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func preferences() throws -> UserDefaults {
        let name = "AVPPlaySelectiveTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testPersonalTeamCapabilityRecoveryRetriesOnlyOnce() throws {
        let defaults = try preferences()
        let team = "FAKE123456"
        let log = URL(fileURLWithPath: "/unused-synthetic-build.log")
        let refusal = ToolchainError.refused(.capability, free: false, log: log)
        XCTAssertTrue(AppleTeams.recoverPersonalTeam(refusal, team: team, defaults: defaults))
        XCTAssertEqual(AppleTeams.refusedAsPaid(defaults: defaults), [team])
        XCTAssertFalse(AppleTeams.recoverPersonalTeam(refusal, team: team, defaults: defaults))
        XCTAssertFalse(AppleTeams.recoverPersonalTeam(ToolchainError.refused(.capability, free: true, log: log),
                                                     team: team, defaults: defaults))
        AppleTeams.forgetFree(team, defaults: defaults)
        XCTAssertEqual(AppleTeams.refusedAsPaid(defaults: defaults), [])
    }

    func testPaidTeamsAndUnrelatedFailuresAreNotReclassified() throws {
        let defaults = try preferences()
        let log = URL(fileURLWithPath: "/unused-synthetic-build.log")
        for error: Error in [InstallError.teamMissing,
                             ToolchainError.refused(.deviceLocked, free: false, log: log),
                             ToolchainError.refused(.tooManyApps, free: true, log: log)] {
            XCTAssertFalse(AppleTeams.recoverPersonalTeam(error, team: "PAID123456", defaults: defaults))
        }
        XCTAssertTrue(AppleTeams.refusedAsPaid(defaults: defaults).isEmpty)
        let xcode: [String: Any] = ["IDEProvisioningTeamByIdentifier": ["fake": [
            ["teamID": "PAID123456", "isFreeProvisioningTeam": false],
            ["teamID": "FREE123456", "isFreeProvisioningTeam": true]
        ]]]
        XCTAssertEqual(AppleTeams.parse(xcode).map(\.free), [false, true])
        let message = "Personal development teams do not support the Extended Virtual Addressing and Low-Latency Streaming capabilities."
        XCTAssertEqual(AppleMessages.refusal(in: message), .capability)
    }

    func testTenMinimumCommitsMatchOfficial146AndCatalogRemainsComplete() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("recipes")
        let expected = [
            "alyx": "a6d33f8", "batman": "dc1a2a8", "moss": "dc1a2a8",
            "store-2285803881494677": "9f12962f71764452fddc25e030ed018d2d86c794",
            "store-24882487241367228": "a6d33f8",
            "store-4015163475201433": "dd8cca30a7b48cae093ec00994061192ea885184",
            "store-5841245619310585": "a6d33f8", "walkabout": "7ed6604",
            "sources/moss.steam": "dc1a2a8", "sources/walkabout.steam": "7ed6604"
        ]
        for (name, commit) in expected {
            let data = try Data(contentsOf: directory.appendingPathComponent(name + ".json"))
            let recipe = try JSONDecoder().decode(Recipe.self, from: data)
            try recipe.validate()
            XCTAssertEqual(recipe.toolchain.minCommit, commit, name)
        }
        let recipes = try RecipeStore(directory: directory).loadAll()
        XCTAssertEqual(recipes.count, 48)
        XCTAssertEqual(recipes.filter { $0.files.contains { $0.role == "apk" } }.count, 47)
        XCTAssertEqual(recipes.first { $0.id == "store-2285803881494677" }?.status.playability, "verified")
        XCTAssertEqual(recipes.first { $0.id == "store-3240283705987790" }?.assetFiles?.count, 6)
        XCTAssertNotNil(recipes.first { $0.id == "store-3647259232032222" })
        XCTAssertNotNil(recipes.first { $0.id == "store-3713270985434472" })
    }

    func testLanguageAndRoomDefaultsStaySeparateAndRespectExplicitRequests() throws {
        let root = try temporaryDirectory()
        let original = root.appendingPathComponent("AVPPlay")
        let modified = root.appendingPathComponent("AVPPlayModificado")
        try InstallDefaults.setGameLanguage("de_DE", base: original)
        try InstallDefaults.setGameLanguage("pt_BR", base: modified)
        try InstallDefaults.setRoomMeasuring(false, base: modified)
        XCTAssertEqual(InstallDefaults.gameLanguage(base: modified), "pt_BR")
        XCTAssertEqual(InstallDefaults.gameLanguage(base: original), "de_DE")
        XCTAssertTrue(InstallDefaults.roomMeasuring(base: original))

        let toolRoot = root.appendingPathComponent("toolchain")
        try FileManager.default.createDirectory(at: toolRoot.appendingPathComponent("visionos"), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: toolRoot.appendingPathComponent("visionos/run.sh"), atomically: true, encoding: .utf8)
        let generator = toolRoot.appendingPathComponent("visionos/gen_xcodeproj.py")
        try "KLEPTON_ROOM_GUARD KLEPTON_GAME_LANGUAGE".write(to: generator, atomically: true, encoding: .utf8)
        let toolchain = try Toolchain(root: toolRoot)
        XCTAssertEqual(InstallDefaults.environment(toolchain: toolchain, base: modified),
                       [Toolchain.roomMeasuringVariable: "0", Toolchain.gameLanguageVariable: "pt_BR"])
        XCTAssertEqual(InstallDefaults.environment(toolchain: toolchain, roomMeasuring: true, gameLanguage: "", base: modified),
                       [Toolchain.roomMeasuringVariable: "1"], "empty request overrides the saved language without changing it")
        XCTAssertEqual(InstallDefaults.gameLanguage(base: modified), "pt_BR")
        try "older generator".write(to: generator, atomically: true, encoding: .utf8)
        XCTAssertEqual(InstallDefaults.environment(toolchain: toolchain, base: modified), [:])
    }

    func testRequestRoundTripKeepsLocalVariantAndNewDefaultsAndReadsOlderJobs() throws {
        var request = InstallRequest(toolchain: "/synthetic-toolchain")
        request.localAPKVariantID = "local-fixture"
        request.localVariantStorePath = "/synthetic-library"
        request.roomMeasuring = false
        request.gameLanguage = "pt_BR"
        let encoded = try JSONEncoder().encode(request)
        XCTAssertEqual(try JSONDecoder().decode(InstallRequest.self, from: encoded), request)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "roomMeasuring")
        object.removeValue(forKey: "gameLanguage")
        let old = try JSONDecoder().decode(InstallRequest.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(old.roomMeasuring)
        XCTAssertNil(old.gameLanguage)
        XCTAssertEqual(old.localAPKVariantID, request.localAPKVariantID)
    }

    func testProgressThrottleLimitsUpdatesWithoutSleeping() {
        let throttle = ProgressThrottle()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(throttle.due(now: now))
        XCTAssertFalse(throttle.due(now: now.addingTimeInterval(0.1)))
        XCTAssertFalse(throttle.due(now: now.addingTimeInterval(0.249)))
        XCTAssertTrue(throttle.due(now: now.addingTimeInterval(0.25)))
        XCTAssertFalse(throttle.due(now: now.addingTimeInterval(0.3)))
        XCTAssertTrue(throttle.due(now: now.addingTimeInterval(0.5)))
    }

    func testDownloadProgressCarriesResumedBytesAndTotalWithoutNetwork() throws {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent("synthetic.partial")
        try Data("abc".utf8).write(to: file)
        let events = LockedBox<[(Int64, Int64?)]>([])
        let delegate = DownloadDelegate(destination: file, offset: 3, progress: { done, total in
            events.set(events.get() + [(done, total)])
        }, authorizedHost: nil)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let url = try XCTUnwrap(URL(string: "https://example.invalid/synthetic"))
        let task = session.dataTask(with: url) // Deliberately never resumed.
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil,
                                                    headerFields: ["Content-Range": "bytes 3-5/6"]))
        delegate.urlSession(session, dataTask: task, didReceive: response) { XCTAssertEqual($0, .allow) }
        delegate.urlSession(session, dataTask: task, didReceive: Data("def".utf8))
        delegate.urlSession(session, task: task, didCompleteWithError: nil)
        XCTAssertEqual(events.get().count, 1)
        XCTAssertEqual(events.get().first?.0, 6)
        XCTAssertEqual(events.get().first?.1, 6)
        XCTAssertEqual(try Data(contentsOf: file), Data("abcdef".utf8))
    }

    func testAlreadyLocalFilesNeverTriggerDownloadProgressOrFetch() async throws {
        let directory = try temporaryDirectory()
        let recipe = RecipeTests().recipe(files: [RecipeTests().file("synthetic.obb")])
        var fetcher = Fetcher(client: MetaClient(token: "unused-synthetic-token"), store: ContentStore(root: directory))
        let events = LockedBox(0)
        fetcher.onProgress = { _ in events.set(events.get() + 1) }
        let summary = try await fetcher.run([PlannedFetch(file: recipe.files[0], action: .keep)], recipe: recipe, log: { _ in })
        XCTAssertEqual(summary.kept, 1)
        XCTAssertEqual(summary.downloaded, 0)
        XCTAssertEqual(events.get(), 0)
    }
}
