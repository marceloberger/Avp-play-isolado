import Foundation

/// A successful empty directory is not an unavailable file service.
enum RemoteListing: Equatable {
    case present([RemoteFile])
    case missingDirectory

    var files: [RemoteFile] {
        if case .present(let files) = self { return files }
        return []
    }
}

public struct RemoteQueryFailure: Error, CustomStringConvertible, Sendable {
    public enum Kind: String, Sendable { case communication, unavailable, inconclusive }
    public let kind: Kind
    public let operation: String
    public let device: String
    public let bundle: String
    public let path: String
    public let detail: String

    init(operation: String, device: String, bundle: String, path: String, underlying: Error) {
        self.operation = operation; self.device = device; self.bundle = bundle; self.path = path
        detail = String(describing: underlying)
        let text = detail.lowercased()
        if ["no paired", "disconnected", "unavailable", "allocate rsd", "locked", "no device"].contains(where: text.contains) {
            kind = .unavailable
        } else if ["timeout", "timed out", "socket", "streamingaction", "network", "connection"].contains(where: text.contains) {
            kind = .communication
        } else {
            kind = .inconclusive
        }
    }

    static func isMissingCandidate(_ error: Error) -> Bool {
        let text = String(describing: error)
        // CoreDevice also emits a generic StreamingAction error for a missing directory.
        // This only permits a parent query; it never establishes absence by itself.
        return text.contains("No such file or directory") || text.contains("NSCocoaErrorDomain Code=260")
            || (text.contains("StreamingAction") && text.lowercased().contains("list of files"))
    }

    public var description: String {
        "Consulta remota interrompida (\(kind.rawValue)); operação=\(operation), dispositivo=\(device), Bundle ID=\(bundle), caminho=\(path). "
        + "Presença dos arquivos não determinada; retome quando a conexão estiver estável. Causa: \(detail)"
    }
}
