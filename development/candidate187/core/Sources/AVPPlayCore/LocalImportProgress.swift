import Foundation

/// A measured current-file count, never a fabricated overall percentage.
public struct LocalImportProgress: Sendable, Equatable {
    public var phase: String
    public var done: Int64
    public var total: Int64
    public init(phase: String, done: Int64 = 0, total: Int64 = 0) {
        self.phase = phase; self.done = done; self.total = total
    }
}

/// Only the Process created by this operation receives SIGINT; never a process group or a shared service.
enum CooperativeProcess {
    static func wait(_ process: Process) throws {
        var interrupted = false
        while process.isRunning {
            if Task.isCancelled && !interrupted {
                process.interrupt()
                interrupted = true
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        process.waitUntilExit()
        try Task.checkCancellation()
    }
}
