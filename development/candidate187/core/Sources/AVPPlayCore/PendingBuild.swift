import Foundation

/// Persists the unsigned artifact before signing; a provisioning/install failure cannot discard it.
enum PendingBuild {
    struct Record: Codable {
        var key: String
        var artifact: ReusableBuild
    }
    static func load(at url: URL, key: String) throws -> ReusableBuild? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: url))
        guard record.key == key else { return nil }
        try record.artifact.verifyCopy(record.artifact.app)
        return record.artifact
    }
    static func save(_ artifact: ReusableBuild, key: String, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Record(key: key, artifact: artifact)).write(to: url, options: .atomic)
    }
}
