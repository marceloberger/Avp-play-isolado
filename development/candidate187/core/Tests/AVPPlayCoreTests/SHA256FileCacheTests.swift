import XCTest
@testable import AVPPlayCore

final class SHA256FileCacheTests: XCTestCase {
    private func fixture() throws -> (URL, SHA256FileCache) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sha-cache-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("fixture.obb")
        try Data(repeating: 0x41, count: 4096).write(to: source)
        return (source, SHA256FileCache(root: dir.appendingPathComponent("cache")))
    }

    func testCachePersistsAcrossInstancesAndManualValidationBypassesIt() throws {
        let (file, cache) = try fixture()
        guard try SHA256FileCache.identity(file).reliable else { throw XCTSkip("Requires a local APFS volume") }
        let events = LockedBox<[Bool]>([])
        let expected = try cache.digest(file) { _, _, cached in events.update { $0.append(cached) } }
        XCTAssertFalse(events.get().contains(true))
        events.set([])
        XCTAssertEqual(try SHA256FileCache(root: cache.root).digest(file) { _, _, cached in events.update { $0.append(cached) } }, expected)
        XCTAssertEqual(events.get(), [true])
        events.set([])
        XCTAssertEqual(try cache.digest(file, forceFull: true) { _, _, cached in events.update { $0.append(cached) } }, expected)
        XCTAssertFalse(events.get().contains(true))
    }

    func testSameSizeChangeAndRestoredModificationTimeInvalidateCache() throws {
        let (file, cache) = try fixture()
        let old = try SHA256FileCache.identity(file)
        let first = try cache.digest(file)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data(repeating: 0x42, count: 4096)); try handle.close()
        try FileManager.default.setAttributes([.modificationDate: attributes[.modificationDate]!], ofItemAtPath: file.path)
        XCTAssertNotEqual(try SHA256FileCache.identity(file), old)
        let cached = LockedBox(false)
        let second = try cache.digest(file) { _, _, hit in if hit { cached.set(true) } }
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(cached.get())
    }

    func testReplacementAtSamePathInvalidatesCache() throws {
        let (file, cache) = try fixture()
        let first = try cache.digest(file)
        try Data(repeating: 0x43, count: 4096).write(to: file, options: .atomic)
        let hits = LockedBox(false)
        XCTAssertNotEqual(try cache.digest(file) { _, _, hit in hits.set(hit) }, first)
        XCTAssertFalse(hits.get())
    }

    func testCorruptOrOldBootCacheCannotProduceAHit() throws {
        let (file, cache) = try fixture()
        let identity = try SHA256FileCache.identity(file)
        guard identity.reliable else { throw XCTSkip("Requires local reliable change metadata") }
        let expected = try cache.digest(file)
        try Data("invalid JSON".utf8).write(to: cache.entryURL(identity))
        let hit = LockedBox(false)
        XCTAssertEqual(try cache.digest(file) { _, _, cached in if cached { hit.set(true) } }, expected)
        XCTAssertFalse(hit.get())
        var entry = try JSONDecoder().decode(SHA256FileCache.Entry.self, from: Data(contentsOf: cache.entryURL(identity)))
        entry.identity.boot = "another boot session"
        try JSONEncoder().encode(entry).write(to: cache.entryURL(identity))
        XCTAssertEqual(try cache.digest(file) { _, _, cached in if cached { hit.set(true) } }, expected)
        XCTAssertFalse(hit.get())
    }

    func testFileChangeDuringHashingIsRejectedWithoutSavingReceipt() throws {
        let (file, cache) = try fixture(), changed = LockedBox(false)
        XCTAssertThrowsError(try cache.digest(file, forceFull: true) { done, _, _ in
            if done == 0, !changed.get() {
                changed.set(true)
                let handle = try! FileHandle(forWritingTo: file)
                try! handle.seekToEnd(); try! handle.write(contentsOf: Data([0x44])); try! handle.close()
            }
        })
        XCTAssertTrue(changed.get())
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.entryURL(try SHA256FileCache.identity(file)).path))
    }

    func testProgressReportsRealBytesAndLeavesSourceUntouched() throws {
        let (file, cache) = try fixture(), values = LockedBox<[Int64]>([])
        let before = try Data(contentsOf: file)
        XCTAssertEqual(try cache.digest(file, forceFull: true) { done, _, _ in values.update { $0.append(done) } }, Hashing.sha256(of: before))
        XCTAssertEqual(values.get().first, 0)
        XCTAssertEqual(values.get().last, Int64(before.count))
        XCTAssertEqual(values.get(), values.get().sorted())
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    func testUncertainFilesystemsNeverQualifyForReuse() {
        XCTAssertTrue(SHA256FileCache.supportsReuse(filesystem: "apfs", local: true))
        XCTAssertFalse(SHA256FileCache.supportsReuse(filesystem: "hfs", local: true))
        for fs in ["ntfs", "exfat", "msdos", "smbfs", "nfs", "unknown"] {
            XCTAssertFalse(SHA256FileCache.supportsReuse(filesystem: fs, local: true), fs)
        }
        XCTAssertFalse(SHA256FileCache.supportsReuse(filesystem: "apfs", local: false))
    }

    func testIncompleteOldCacheMetadataRequiresFullRead() throws {
        let (file, cache) = try fixture()
        let identity = try SHA256FileCache.identity(file)
        guard identity.reliable else { throw XCTSkip("Requires local reliable metadata") }
        let expected = try cache.digest(file)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: cache.entryURL(identity))) as? [String: Any])
        var fields = try XCTUnwrap(json["identity"] as? [String: Any])
        fields.removeValue(forKey: "ctimeNS"); json["identity"] = fields
        try JSONSerialization.data(withJSONObject: json).write(to: cache.entryURL(identity))
        let hit = LockedBox(false)
        XCTAssertEqual(try cache.digest(file) { _, _, cached in if cached { hit.set(true) } }, expected)
        XCTAssertFalse(hit.get())
    }

    func testCancellationKeepsMainActorResponsiveAndNeverContinuesToCompilation() async throws {
        let (file, cache) = try fixture()
        let recipes = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("recipes")
        let recipe = try RecipeStore(directory: recipes).load(id: "store-2637179839719680")
        let store = JobStore(directory: file.deletingLastPathComponent().appendingPathComponent("jobs"))
        let runtime = try Verified850Fixture.source()
        let job = Job(recipe: recipe, request: InstallRequest(toolchain: runtime.root.path),
                      steps: [.fetch, .buildOnly], toolchainCommit: runtime.commit())
        try store.save(job)
        let started = expectation(description: "background hashing started"), release = DispatchSemaphore(value: 0)
        let compiled = LockedBox(false), once = LockedBox(false)
        let worker = Task.detached {
            try await JobRunner(store: store).run(job, currentToolchain: runtime.commit()) { step, _ in
                if step == .buildOnly { compiled.set(true); XCTFail("No compilation permitted in this test"); return }
                _ = try cache.digest(file, forceFull: true) { done, _, _ in
                    if done == 0, !once.get() {
                        once.set(true); started.fulfill()
                        _ = release.wait(timeout: .now() + 5)
                    }
                }
            }
        }
        await fulfillment(of: [started], timeout: 3)
        let heartbeat = await MainActor.run { true }
        XCTAssertTrue(heartbeat)
        worker.cancel(); release.signal()
        do { _ = try await worker.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(compiled.get())
        XCTAssertEqual(try store.load(job.id).state, .cancelled)
        XCTAssertTrue(try store.load(job.id).completed.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.entryURL(try SHA256FileCache.identity(file)).path))
    }
    func testConcurrentJobsShareOneRead() async throws {
        let (file, cache) = try fixture()
        guard try SHA256FileCache.identity(file).reliable else { throw XCTSkip("Requires APFS") }
        let reads = LockedBox(0), hits = LockedBox(0)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    _ = try SHA256FileCache(root: cache.root).digest(file) { done, _, cached in
                        if done == 0 { reads.update { $0 += 1 } }
                        if cached { hits.update { $0 += 1 } }
                    }
                }
            }
            try await group.waitForAll()
        }
        XCTAssertEqual(reads.get(), 1)
        XCTAssertEqual(hits.get(), 7)
    }

    func testAuditLogsMissHitManualAndInvalidation() throws {
        let (file, cache) = try fixture()
        guard try SHA256FileCache.identity(file).reliable else { throw XCTSkip("Requires APFS") }
        _ = try cache.digest(file)
        _ = try SHA256FileCache(root: cache.root).digest(file)
        _ = try cache.digest(file, forceFull: true)
        try Data(repeating: 0x42, count: 4096).write(to: file)
        _ = try cache.digest(file)
        let audit = try String(contentsOf: cache.root.appendingPathComponent("validation.log"), encoding: .utf8)
        for text in ["registro ausente", "reutilizado do cache", "leitura integral solicitada", "mudaram"] {
            XCTAssertTrue(audit.contains(text), text)
        }
    }

    func testUncertainFilesystemRequiresFullReadWithExplicitReason() throws {
        let (file, _) = try fixture()
        var identity = try SHA256FileCache.identity(file)
        for fs in ["ntfs", "exfat", "smbfs"] {
            identity.filesystem = fs; identity.reliable = false
            let entry = SHA256FileCache.Entry(schema: 1, identity: identity, sha256: String(repeating: "a", count: 64))
            let reason = SHA256FileCache.invalidation(entry, identity: identity, forceFull: false, safeRoot: true)
            XCTAssertTrue(reason?.contains(fs) == true)
            XCTAssertTrue(reason?.contains("leitura integral obrigatória") == true)
        }
    }

}
