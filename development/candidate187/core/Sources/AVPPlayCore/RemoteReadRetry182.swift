import Foundation

/// Bounded retries for reads only. Integrity, identity ambiguity and malformed results
/// never authorize another attempt, and exhaustion preserves the original failure.
enum RemoteReadRetry182 {
    static func isTransient(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        let detail: String
        if case DeviceError.fileQuery(let failure) = error { detail = failure.detail.lowercased() }
        else { detail = String(describing: error).lowercased() }
        // A nested transport message must not make an identity/integrity rejection retryable.
        if ["identidade", "identity", "sha-256", "recibo", "receipt", "invalid json", "json inválid", "inconclusiv"].contains(where: detail.contains) { return false }
        if case DeviceError.fileQuery(let failure) = error {
            return failure.kind == .communication || failure.kind == .unavailable
        }
        guard case DeviceError.tool(let text) = error else { return false }
        let value = text.lowercased()
        return ["timed out", "timeout", "socket was closed", "connection reset", "connection to the remote device",
                "device disconnected", "streamingaction", "allocate rsd"].contains(where: value.contains)
    }

    static func run<T>(attempts: Int = 3, pause: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
                       report: (String) -> Void = { _ in }, _ read: () throws -> T) throws -> T {
        precondition((1...3).contains(attempts))
        for attempt in 1...attempts {
            try Task.checkCancellation()
            do { return try read() }
            catch {
                guard attempt < attempts, isTransient(error) else { throw error }
                report("Leitura remota interrompida; nova tentativa \(attempt + 1)/\(attempts). Causa: \(error)")
                pause(0.25 * Double(attempt))
                try Task.checkCancellation()
            }
        }
        fatalError("unreachable")
    }
}
