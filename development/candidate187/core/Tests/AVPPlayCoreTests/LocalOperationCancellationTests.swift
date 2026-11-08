import XCTest
@testable import AVPPlayCore

final class LocalOperationCancellationTests: XCTestCase {
    func testCopyCancellationPreservesSourceAndEarlierResultAndMeasuresBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("import-cancel-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("original.apk"), target = root.appendingPathComponent("new-stage.apk")
        let earlier = root.appendingPathComponent("earlier-result.app")
        let bytes = Data(repeating: 17, count: 24 << 20)
        try bytes.write(to: source); try Data("preserve".utf8).write(to: earlier)
        let reached = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let measurements = LockedBox<[LocalImportProgress]>([])
        let worker = Task.detached {
            try LocalAPKVariantStore.copyForImport(source, to: target, total: Int64(bytes.count)) { value in
                measurements.update { $0.append(value) }
                if value.done == 8 << 20 { reached.signal(); _ = release.wait(timeout: .now() + 5) }
            }
        }
        let signalled = await Task.detached { reached.wait(timeout: .now() + 5) == .success }.value
        XCTAssertTrue(signalled)
        worker.cancel(); release.signal()
        do { try await worker.value; XCTFail("Expected cooperative cancellation") } catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertEqual(try String(contentsOf: earlier), "preserve")
        XCTAssertLessThan(ContentStore.fileSize(target) ?? 0, Int64(bytes.count))
        XCTAssertTrue(measurements.get().allSatisfy { $0.done > 0 && $0.done <= $0.total })
    }

    func testCancellationInterruptsOnlyOwnedChildAndLeavesSiblingRunning() async throws {
        let sibling = Process(); sibling.executableURL = URL(fileURLWithPath: "/bin/sleep"); sibling.arguments = ["30"]
        try sibling.run()
        defer { if sibling.isRunning { sibling.terminate(); sibling.waitUntilExit() } }
        let ready = DispatchSemaphore(value: 0)
        let child = LockedBox<Process?>(nil)
        let worker = Task.detached {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sleep"); process.arguments = ["30"]
            try process.run(); child.set(process); ready.signal()
            try CooperativeProcess.wait(process)
        }
        let signalled = await Task.detached { ready.wait(timeout: .now() + 5) == .success }.value
        XCTAssertTrue(signalled)
        worker.cancel()
        do { try await worker.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertFalse(try XCTUnwrap(child.get()).isRunning)
        XCTAssertTrue(sibling.isRunning, "Never interrupt another operation or a shared process")
    }
}
