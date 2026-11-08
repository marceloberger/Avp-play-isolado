import CryptoKit
import Foundation

public enum Hashing {
    /// SHA-256 einer Datei als Hex-Text, in Blöcken gelesen (auch für Dateien im GB-Bereich).
    public static func sha256(of url: URL, progress: @Sendable (Int64) -> Void = { _ in }) throws -> String {
        try Task.checkCancellation()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var done: Int64 = 0
        var lastProgress = ProcessInfo.processInfo.systemUptime
        progress(0)
        while true {
            try Task.checkCancellation()
            let more: Bool = try autoreleasepool {
                guard let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty else { return false }
                try Task.checkCancellation()
                hasher.update(data: chunk)
                done += Int64(chunk.count)
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastProgress >= 0.1 { progress(done); lastProgress = now }
                return true
            }
            if !more { break }
        }
        progress(done)
        try Task.checkCancellation()
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-256 von Daten im Speicher als Hex-Text.
    public static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
