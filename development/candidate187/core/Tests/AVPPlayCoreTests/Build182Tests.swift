import XCTest
@testable import AVPPlayCore

final class Build182Tests: XCTestCase {
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("avp182-fixture-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func entry(_ path: String) -> InstallationContent.Entry {
        .init(source: URL(fileURLWithPath: "/synthetic/source"), destination: path, size: 3, sha256: String(repeating: "a", count: 64))
    }
    func testPreflight63FileBenchmark125ListingsBecome11WithIdenticalResults() throws {
        var entries = (0..<55).map { entry("Documents/obb/file\($0).pak") }
        entries += [entry("Documents/game.apk"), entry("Documents/target/AndroidManifest.xml"), entry("Documents/target/apktool.yml"),
                    entry("Documents/target/assets/a"), entry("Documents/target/assets/b"),
                    entry("Documents/target/assets/memoryadvice/a"), entry("Documents/target/assets/memoryadvice/b")]
        let first = entries
        entries.append(entry("Documents/android-files/index.txt"))
        XCTAssertEqual(entries.count, 63)
        let remote = Dictionary(uniqueKeysWithValues: entries.map { ($0.destination, RemoteFile(relativePath: ($0.destination as NSString).lastPathComponent, size: 3, isDirectory: false)) })
        var baseline = 0, grouped = 0
        for manifest in [first, entries] {
            let old = try InstallationContent.preflight(manifest, stat: { baseline += 1; return remote[$0] })
            let new = try InstallationContent.preflight(manifest, stat: { _ in XCTFail("Batched preflight must not stat per file"); return nil }, list: { parent in
                grouped += 1
                return remote.filter { ($0.key as NSString).deletingLastPathComponent == parent }.map(\.value)
                    + [RemoteFile(relativePath: ".DS_Store", size: 4, isDirectory: false)]
            })
            XCTAssertEqual(old, new)
        }
        XCTAssertEqual(baseline, 125); XCTAssertEqual(grouped, 11)
        print("BUILD182_METRIC preflight_callbacks baseline=\(baseline) grouped=\(grouped) files=63; no real device timing measured")
    }
    func testBatchedPreflightFailureAndDuplicateNeverAuthorizeUpload() throws {
        let root = try scratch(), expected = [entry("Documents/a"), entry("Documents/metadata/b")]
        var puts = 0
        let container = InstallationContent.Container(stat: { _ in nil }, fetch: { _, _ in XCTFail() },
            put: { _, _ in puts += 1 }, list: { parent in
                if parent.contains("metadata") { throw DeviceError.tool("StreamingAction: list unavailable") }
                return []
            })
        XCTAssertThrowsError(try InstallationContent.sync(expected, container: container, receipts: root.appendingPathComponent("receipts.json")))
        XCTAssertEqual(puts, 0)
        XCTAssertThrowsError(try InstallationContent.preflight(expected, stat: { _ in nil }, list: { _ in
            [RemoteFile(relativePath: "a", size: 3, isDirectory: false), RemoteFile(relativePath: "a", size: 3, isDirectory: false)]
        }))
    }
    func testReadRetryIsBoundedAndNeverRetriesIntegrityIdentityOrCancellation() throws {
        var calls = 0, waits: [TimeInterval] = []
        let value = try RemoteReadRetry182.run(pause: { waits.append($0) }) { () throws -> Int in
            calls += 1
            if calls < 3 { throw DeviceError.tool("StreamingAction: failed to get a list of files") }
            return 7
        }
        XCTAssertEqual(value, 7); XCTAssertEqual(calls, 3); XCTAssertEqual(waits, [0.25, 0.5])
        for error: Error in [DeviceError.tool("SHA-256 mismatch"), DeviceError.tool("Identidade inconclusiva: apps=0"), CancellationError(), DeviceError.tool("invalid JSON")] {
            var count = 0
            XCTAssertThrowsError(try RemoteReadRetry182.run(pause: { _ in XCTFail() }) { () throws -> Int in count += 1; throw error })
            XCTAssertEqual(count, 1)
        }
        var exhausted = 0
        XCTAssertThrowsError(try RemoteReadRetry182.run(pause: { _ in }) { () throws -> Int in exhausted += 1; throw DeviceError.tool("socket was closed") })
        XCTAssertEqual(exhausted, 3)
    }
    func testReadbackDisconnectRetriesWithoutUploadAndKeepsFinalHashCheck() throws {
        let root = try scratch(), bytes = Data("payload".utf8), source = root.appendingPathComponent("source")
        try bytes.write(to: source)
        let file = try InstallationContent.entry(source: source, destination: "Documents/game.apk")
        var reads = 0, writes = 0
        let remote = RemoteFile(relativePath: "game.apk", size: Int64(bytes.count), isDirectory: false, modified: Date(timeIntervalSince1970: 1))
        let container = InstallationContent.Container(stat: { _ in remote }, fetch: { _, url in
            reads += 1
            if reads == 1 { try Data("partial".utf8).write(to: url); throw DeviceError.tool("connection to the remote device is no longer valid") }
            try bytes.write(to: url)
        }, put: { _, _ in writes += 1 })
        var progress: [InstallationContent.SyncProgress182] = []
        try InstallationContent.sync([file], container: container, receipts: root.appendingPathComponent("receipt.json"), progress: { progress.append($0) })
        XCTAssertEqual(reads, 2); XCTAssertEqual(writes, 0)
        XCTAssertEqual(progress.last?.bytesReadBack, Int64(bytes.count)); XCTAssertEqual(progress.last?.filesVerified, 1)
    }
    func testMeasuredProgressAndResumeAvoidReadbackAndUploadForValidReceipt() throws {
        let root = try scratch(), source = root.appendingPathComponent("source"), bytes = Data("payload".utf8)
        try bytes.write(to: source)
        let file = try InstallationContent.entry(source: source, destination: "Documents/game.apk")
        let remote = InstallationHardeningTests.Remote(); let receipts = root.appendingPathComponent("receipt.json")
        var last: InstallationContent.SyncProgress182?
        try InstallationContent.sync([file], container: remote.container, receipts: receipts, progress: { last = $0 })
        XCTAssertEqual(last?.bytesUploaded, Int64(bytes.count)); XCTAssertEqual(last?.bytesVerified, Int64(bytes.count)); XCTAssertEqual(last?.filesVerified, 1)
        let reads = remote.reads, uploads = remote.uploads
        try InstallationContent.sync([file], container: remote.container, receipts: receipts, progress: { last = $0 })
        XCTAssertEqual(remote.reads, reads); XCTAssertEqual(remote.uploads, uploads)
        XCTAssertEqual(last?.receiptHits, 1); XCTAssertEqual(last?.bytesUploaded, 0); XCTAssertEqual(last?.bytesReadBack, 0)
    }
    func testLocalAdmissionIsIdempotentWithoutRewritingJobAndRejectsChangedDevice() throws {
        let root = try scratch(), recipe = try ResumeReuseTests().recipe(), store = JobStore(directory: root)
        var request = InstallRequest(toolchain: "/fixture/runtime"); request.localAPKVariantID = "variant"; request.device = "device-a"
        let first = Job(recipe: recipe, request: request, steps: [.fetch, .build, .stage], toolchainCommit: "cc2856c")
        let admitted = try store.admitLocal182(first)
        XCTAssertTrue(admitted.inserted)
        let file = root.appendingPathComponent(first.id + ".json"), bytes = try Data(contentsOf: file)
        let second = Job(recipe: recipe, request: request, steps: first.steps, toolchainCommit: "cc2856c")
        let existing = try store.admitLocal182(second)
        XCTAssertFalse(existing.inserted); XCTAssertEqual(existing.job.id, first.id)
        XCTAssertEqual(try Data(contentsOf: file), bytes); XCTAssertEqual(store.all().count, 1)
        request.device = "another-device"
        XCTAssertThrowsError(try store.admitLocal182(Job(recipe: recipe, request: request, steps: first.steps, toolchainCommit: "cc2856c")))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
    func testLibraryContainsOnlyImportedOrRecordedGamesAndDoesNotInventInstallations() throws {
        let helper = FunctionalityConfirmationTests(), (recipe, variant, store) = try helper.fixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: store.root.deletingLastPathComponent()) }
        XCTAssertTrue(try VisualLibrary182.entries(recipes: [recipe], variants: [], jobs: [], installations: []).isEmpty)
        let imported = try VisualLibrary182.entries(recipes: [recipe], variants: [variant], jobs: [], installations: [])
        XCTAssertEqual(imported.count, 1); XCTAssertEqual(imported[0].status, .pending)
        var request = InstallRequest(toolchain: "/fixture"); request.localAPKVariantID = variant.id
        var build = Job(recipe: recipe, request: request, steps: [.buildOnly], toolchainCommit: "cc2856c")
        build.state = .finished; build.completed = [.buildOnly]
        XCTAssertEqual(try VisualLibrary182.entries(recipes: [recipe], variants: [variant], jobs: [build], installations: [])[0].status, .prepared)
        var native = build; native.steps = [.build]; native.completed = [.build]
        let receipt = try helper.receipt(variant, recipe: recipe)
        XCTAssertEqual(try VisualLibrary182.entries(recipes: [recipe], variants: [variant], jobs: [native], installations: [receipt])[0].status, .pending)
    }
    func testLibraryInstalledRequiresExactStageOrUserTestimonyAndSupportsSearchFilter() throws {
        let helper = FunctionalityConfirmationTests(), (recipe, variant, store) = try helper.fixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: store.root.deletingLastPathComponent()) }
        let receipt = try helper.receipt(variant, recipe: recipe)
        var request = receipt.configuration!; request.localAssetsSHA256 = receipt.build?.assetsSHA256
        var stage = Job(recipe: recipe, request: request, steps: [.stage], toolchainCommit: "cc2856c")
        stage.state = .finished; stage.completed = [.stage]; stage.updated = receipt.date.addingTimeInterval(1)
        let card = try XCTUnwrap(VisualLibrary182.entries(recipes: [recipe], variants: [variant], jobs: [stage], installations: [receipt]).first)
        XCTAssertEqual(card.status, .installed)
        XCTAssertTrue(card.matches(search: recipe.package, status: .installed))
        XCTAssertFalse(card.matches(search: "unknown", status: nil)); XCTAssertFalse(card.matches(search: "", status: .pending))
        stage.request.device = "another-device"
        XCTAssertEqual(try VisualLibrary182.entries(recipes: [recipe], variants: [variant], jobs: [stage], installations: [receipt])[0].status, .pending)
        var changed = variant; changed.sha256 = String(repeating: "e", count: 64)
        XCTAssertNotEqual(try VisualLibrary182.entries(recipes: [recipe], variants: [changed], jobs: [stage], installations: [receipt])[0].status, .installed)
    }
    func testArtworkCacheRequiresHashBoundProvenanceAndUsesNoInventedImage() throws {
        let root = try scratch(), cache = LibraryArtwork182(directory: root)
        XCTAssertNil(cache.cached(appID: "123")); XCTAssertNil(cache.existing(appID: nil, paths: []))
        XCTAssertNil(cache.cached(appID: "../escape"))
        try Data("invalid".utf8).write(to: root.appendingPathComponent("123.jpg"))
        let origin = LibraryArtwork182.Origin(source: "fixture", page: nil, image: "file:///fixture", sha256: "wrong", cachedAt: Date())
        try JSONEncoder().encode(origin).write(to: root.appendingPathComponent("123.origin.json"))
        XCTAssertNil(cache.cached(appID: "123"))
    }
}

extension Build182Tests {
    func testReadinessRequiresFinishedStageNotNativeInstallOrPartialStage() throws {
        let recipe = try ResumeReuseTests().recipe()
        var job = Job(recipe: recipe, request: InstallRequest(toolchain: "/fixture"), steps: [.build], toolchainCommit: "cc2856c")
        job.state = .finished; job.completed = [.build]
        XCTAssertTrue(job.localCompletion182.contains("pendente"))
        job.steps = [.stage]; job.completed = []; job.state = .failed
        XCTAssertTrue(job.localCompletion182.contains("incompleta"))
        job.state = .finished; job.completed = [.stage]
        XCTAssertTrue(job.localCompletion182.contains("verificados"))
    }
}

extension Build182Tests {
    func testOrphanVariantAndProvisionalRemainVisibleWithoutFakeInstallation() throws {
        let helper = FunctionalityConfirmationTests(), (recipe, variant, store) = try helper.fixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: store.root.deletingLastPathComponent()) }
        let orphan = try VisualLibrary182.entries(recipes: [], variants: [variant], jobs: [], installations: [])
        XCTAssertEqual(orphan.count, 1); XCTAssertEqual(orphan[0].status, .pending); XCTAssertNil(orphan[0].recipe)
        let provisional = LocalProvisionalRecipe(apkSHA256: variant.sha256, apkSize: variant.size, apkPath: "/fixture.apk",
            title: recipe.title, package: variant.package, versionName: "fixture", versionCode: variant.versionCode,
            architectures: ["arm64-v8a"], nativeLibraries: [], assets: [], externalFileReferences: [], externalFiles: [], createdAt: Date())
        let cards = try VisualLibrary182.entries(recipes: [], variants: [variant], jobs: [], installations: [], provisional: [provisional])
        XCTAssertEqual(cards.count, 1); XCTAssertEqual(cards[0].status, .experimental)
        XCTAssertTrue(cards[0].provisional); XCTAssertEqual(cards[0].id, provisional.id)
    }
}

extension Build182Tests {
    func testNestedCommunicationDoesNotRetryIdentityOrIntegrityRejection() throws {
        for text in ["Identidade inconclusiva após 3 consultas; causa StreamingAction", "SHA-256 falhou; socket was closed", "Recibo inválido; connection reset"] {
            var calls = 0
            XCTAssertThrowsError(try RemoteReadRetry182.run(pause: { _ in XCTFail() }) { () throws -> Int in
                calls += 1; throw DeviceError.tool(text)
            })
            XCTAssertEqual(calls, 1)
        }
    }
    func testAdmissionLockSymlinkFailsClosedWithoutCreatingJob() throws {
        let root = try scratch(), store = JobStore(directory: root), target = root.appendingPathComponent("protected")
        try Data("untouched".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".admission182.lock"), withDestinationURL: target)
        var request = InstallRequest(toolchain: "/fixture"); request.localAPKVariantID = "fixture"
        let job = Job(recipe: try ResumeReuseTests().recipe(), request: request, steps: [.stage], toolchainCommit: "cc2856c")
        XCTAssertThrowsError(try store.admitLocal182(job))
        XCTAssertTrue(store.all().isEmpty); XCTAssertEqual(try Data(contentsOf: target), Data("untouched".utf8))
    }
}

extension Build182Tests {
    func testExternalRecordsAreReadOnlyAndNeverMergeInstallationIdentity() throws {
        let helper = FunctionalityConfirmationTests(), (recipe, variant, store) = try helper.fixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: store.root.deletingLastPathComponent()) }
        var primary = try VisualLibrary182.entries(recipes: [recipe], variants: [variant], jobs: [], installations: [])
        let original = primary[0]
        let sameGame = try VisualLibrary182.entries(recipes: [recipe], variants: [variant], jobs: [], installations: [])
        VisualLibrary182.appendReadOnly(sameGame, source: "Legacy", to: &primary)
        XCTAssertEqual(primary.count, 1); XCTAssertFalse(primary[0].readOnly)
        XCTAssertEqual(primary[0].status, original.status); XCTAssertEqual(primary[0].jobs, original.jobs)
        XCTAssertTrue(primary[0].evidence.contains("sem unificar identidades"))
        var otherRecipe = recipe; otherRecipe.id = "other"; otherRecipe.package = "example.other"
        var otherVariant = variant; otherVariant.recipeID = otherRecipe.id; otherVariant.package = otherRecipe.package
        let secondary = try VisualLibrary182.entries(recipes: [otherRecipe], variants: [otherVariant], jobs: [], installations: [])
        VisualLibrary182.appendReadOnly(secondary, source: "Legacy", to: &primary)
        let external = try XCTUnwrap(primary.first { $0.readOnly })
        XCTAssertEqual(external.sourceLabel, "Legacy"); XCTAssertEqual(external.status, .pending)
        XCTAssertEqual(external.recipe?.id, "other"); XCTAssertTrue(external.id.hasPrefix("readonly:Legacy:"))
        XCTAssertEqual(secondary[0].id, "other", "Original record is never renamed")
    }
}

extension Build182Tests {
    func testProvisionalCommunityTitleRequiresPersistedExactPackageAndVersion() throws {
        var provisional = LocalProvisionalRecipe(apkSHA256: String(repeating: "a", count: 64), apkSize: 1,
            apkPath: "/fixture.apk", title: "com.XrealGames.Zc15", package: "com.XrealGames.Zc15",
            versionName: "2.0.1173-S-80237", versionCode: "1173", architectures: ["arm64-v8a"],
            nativeLibraries: [], assets: [], externalFileReferences: [], externalFiles: [], createdAt: Date())
        provisional.communityTarget = CommunityKleptonTarget.known[0]
        let entry = try XCTUnwrap(VisualLibrary182.entries(recipes: [], variants: [], jobs: [], installations: [], provisional: [provisional]).first)
        XCTAssertEqual(entry.title, "Zero Caliber 2"); XCTAssertEqual(entry.status, .experimental)
        XCTAssertEqual(entry.artworkAppID, "6072194326150034")
        provisional.communityTarget = CommunityKleptonTarget(appID: "6072194326150034", packageID: provisional.package,
            target: "x6072194326150034", versionName: "different", versionCode: "999", title: "Do not accept",
            status: "community", provenance: "fixture")
        let mismatch = try XCTUnwrap(VisualLibrary182.entries(recipes: [], variants: [], jobs: [], installations: [], provisional: [provisional]).first)
        XCTAssertEqual(mismatch.title, provisional.title); XCTAssertNil(mismatch.artworkAppID)
    }
}
