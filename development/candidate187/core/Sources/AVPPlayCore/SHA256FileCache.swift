import Foundation
import Darwin

public struct LocalValidationProgress: Sendable, Equatable {
    public var file: String
    public var index: Int
    public var count: Int
    public var done: Int64
    public var total: Int64
    public var cached: Bool
    public var message: String?
    public init(file: String, index: Int, count: Int, done: Int64, total: Int64, cached: Bool = false, message: String? = nil) {
        self.file = file; self.index = index; self.count = count; self.done = done; self.total = total; self.cached = cached; self.message = message
    }
}

/// An optimization, never an authenticity/ownership record. Unknown filesystems are hashed fully.
/// Entries are reusable only for the same boot, volume, inode and nanosecond change timestamps.
public struct SHA256FileCache: Sendable {
    public static var shared: SHA256FileCache {
        SHA256FileCache(root: DataLocation.base.appendingPathComponent("local-variants/.sha256-cache"))
    }
    // Serialize competing validations of the same canonical file across Jobs/cache instances.
    // A waiter rechecks current metadata and the persistent receipt after the first reader finishes.
    private static let gates = Gates()
    private final class Gates: @unchecked Sendable {
        let lock = NSLock()
        var paths: [String: NSLock] = [:]
        func gate(_ path: String) -> NSLock {
            lock.lock(); defer { lock.unlock() }
            if let gate = paths[path] { return gate }
            let gate = NSLock(); paths[path] = gate; return gate
        }
    }
    public let root: URL
    private let unreliablePaths: Set<String>
    private let contentReadObserver: (@Sendable (URL, Int64) -> Void)?
    public init(root: URL) {
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
        unreliablePaths = []; contentReadObserver = nil
    }

    /// Test instrumentation can only lower trust, never mark an untrusted filesystem reliable.
    init(root: URL, unreliablePaths: Set<String>, contentReadObserver: @escaping @Sendable (URL, Int64) -> Void) {
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
        self.unreliablePaths = unreliablePaths; self.contentReadObserver = contentReadObserver
    }

    func currentIdentity(_ url: URL) throws -> Identity {
        var result = try Self.identity(url)
        if unreliablePaths.contains(result.path) { result.reliable = false; result.filesystem = "ntfs" }
        return result
    }

    func auditValidation(_ message: String) {
        Self.gates.lock.lock(); defer { Self.gates.lock.unlock() }
        guard root.resolvingSymlinksInPath().standardizedFileURL.path == root.path else { return }
        let file = root.appendingPathComponent("validation.log")
        guard (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if !FileManager.default.fileExists(atPath: file.path) {
                FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("\(ISO8601DateFormatter().string(from: Date())) [Validação] \(message)\n".utf8))
        } catch { /* Logging failure must not convert a failed integrity check into success. */ }
    }

    struct Identity: Codable, Equatable, Sendable {
        var path: String
        var device: Int32
        var inode: UInt64
        var size: Int64
        var mtime: Int64
        var mtimeNS: Int64
        var ctime: Int64
        var ctimeNS: Int64
        var birth: Int64
        var birthNS: Int64
        var boot: String
        var filesystem: String
        var volume: String
        var reliable: Bool
    }
    struct Entry: Codable { var schema: Int; var identity: Identity; var sha256: String }

    static func supportsReuse(filesystem: String, local: Bool) -> Bool {
        local && filesystem.lowercased() == "apfs"
    }

    static func identity(_ url: URL) throws -> Identity {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        var info = stat(), fs = statfs(), boot = timeval()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              statfs(path, &fs) == 0 else { throw LocalAPKVariantError.missing(path) }
        var size = MemoryLayout<timeval>.size
        let hasBoot = sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0
        let filesystem = withUnsafePointer(to: &fs.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
        }
        let volume = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString) ?? ""
        // HFS (coarse timestamps), NTFS, network shares, FAT/exFAT and unknown drivers do not provide sufficiently
        // dependable change metadata for persistent reuse. A full read is mandatory there.
        let reliable = hasBoot && !volume.isEmpty && supportsReuse(filesystem: filesystem,
            local: fs.f_flags & UInt32(MNT_LOCAL) != 0) && info.st_ino != 0 && info.st_ctimespec.tv_nsec != 0
        return Identity(path: path, device: info.st_dev, inode: info.st_ino, size: info.st_size,
            mtime: Int64(info.st_mtimespec.tv_sec), mtimeNS: Int64(info.st_mtimespec.tv_nsec),
            ctime: Int64(info.st_ctimespec.tv_sec), ctimeNS: Int64(info.st_ctimespec.tv_nsec),
            birth: Int64(info.st_birthtimespec.tv_sec), birthNS: Int64(info.st_birthtimespec.tv_nsec),
            boot: "\(boot.tv_sec):\(boot.tv_usec)", filesystem: filesystem, volume: volume, reliable: reliable)
    }

    func entryURL(_ identity: Identity) -> URL {
        root.appendingPathComponent(Hashing.sha256(of: Data(identity.path.utf8)) + ".json")
    }

    /// Returns a cached digest only when current filesystem identity proves that the cache entry still
    /// refers to the same reliable local file. This never reads the file contents or creates a cache entry.
    func cachedDigestIfCurrent(_ url: URL) -> String? {
        guard let before = try? currentIdentity(url), before.reliable else { return nil }
        let safeRoot = root.resolvingSymlinksInPath().standardizedFileURL.path == root.path
        guard safeRoot else { return nil }
        let entry = entryURL(before)
        guard (try? entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              let data = try? Data(contentsOf: entry),
              let cached = try? JSONDecoder().decode(Entry.self, from: data),
              Self.invalidation(cached, identity: before, forceFull: false, safeRoot: true) == nil,
              let after = try? currentIdentity(url), after == before else { return nil }
        return cached.sha256.lowercased()
    }

    static func invalidation(_ cached: Entry?, identity: Identity, forceFull: Bool, safeRoot: Bool) -> String? {
        if forceFull { return "leitura integral solicitada; reutilização desativada nesta verificação" }
        if !safeRoot { return "diretório do cache mudou ou contém link simbólico" }
        if !identity.reliable { return "sistema de arquivos \(identity.filesystem): sem identidade/metadados confiáveis; leitura integral obrigatória" }
        guard let cached else { return "registro ausente, ilegível ou incompleto" }
        guard cached.schema == 1, cached.sha256.count == 64, cached.sha256.allSatisfy({ $0.isHexDigit }) else {
            return "formato ou digest do registro inválido"
        }
        let old = cached.identity
        if old.boot != identity.boot { return "sessão de inicialização do Mac mudou" }
        if old.volume != identity.volume || old.device != identity.device { return "volume ou montagem mudou" }
        if old.inode != identity.inode || old.birth != identity.birth || old.birthNS != identity.birthNS { return "arquivo substituído" }
        if old.size != identity.size { return "tamanho mudou" }
        if old != identity { return "identidade, permissões ou datas de alteração mudaram" }
        return nil
    }

    public func digest(_ url: URL, forceFull: Bool = false,
                       log: @Sendable (String) -> Void = { _ in },
                       progress: @Sendable (Int64, Int64, Bool) -> Void = { _, _, _ in }) throws -> String {
        try Task.checkCancellation()
        let gate = Self.gates.gate(url.resolvingSymlinksInPath().standardizedFileURL.path)
        while !gate.lock(before: Date().addingTimeInterval(0.1)) { try Task.checkCancellation() }
        defer { gate.unlock() }
        try Task.checkCancellation()
        let before = try currentIdentity(url)
        let entry = entryURL(before)
        let safeRoot = root.resolvingSymlinksInPath().standardizedFileURL.path == root.path
        let linked = (try? entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
        let cached = !linked ? (try? Data(contentsOf: entry)).flatMap { try? JSONDecoder().decode(Entry.self, from: $0) } : nil
        func note(_ message: String) {
            let text = "[SHA-256] \(url.lastPathComponent): \(message)"
            log(text)
            // All entry points (including import/Prepare outside a Job) retain a diagnostic log.
            Self.gates.lock.lock(); defer { Self.gates.lock.unlock() }
            guard safeRoot else { return }
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let audit = root.appendingPathComponent("validation.log")
                guard (try? audit.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return }
                if !FileManager.default.fileExists(atPath: audit.path) { FileManager.default.createFile(atPath: audit.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
                let handle = try FileHandle(forWritingTo: audit); defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data("\(ISO8601DateFormatter().string(from: Date())) \(text) · \(before.path)\n".utf8))
            } catch { log("[SHA-256] Não foi possível persistir o log: \(error)") }
        }
        let reason = Self.invalidation(cached, identity: before, forceFull: forceFull, safeRoot: safeRoot)
        if reason == nil, let cached, try currentIdentity(url) == before {
            try Task.checkCancellation()
            note("SHA-256 reutilizado do cache; identidade APFS confirmada")
            progress(before.size, before.size, true)
            return cached.sha256
        }
        note("SHA-256 calculado novamente. Motivo da invalidação do cache: \(reason ?? "arquivo mudou durante a consulta")")
        let hash = try Hashing.sha256(of: url) { done in
            contentReadObserver?(url, done)
            progress(done, before.size, false)
        }
        try Task.checkCancellation()
        guard try currentIdentity(url) == before else {
            note("Resultado descartado: arquivo mudou durante a leitura")
            throw LocalAPKVariantError.invalidRecord("File changed during SHA-256 verification: \(url.lastPathComponent). Retry with stable files.")
        }
        if before.reliable, safeRoot {
            do {
                guard root.resolvingSymlinksInPath().standardizedFileURL.path == root.path else { return hash }
                let data = try JSONEncoder().encode(Entry(schema: 1, identity: before, sha256: hash))
                try data.write(to: entry, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: entry.path)
            } catch { note("Resultado válido, mas cache não persistido: \(error)") }
        }
        return hash
    }
}
