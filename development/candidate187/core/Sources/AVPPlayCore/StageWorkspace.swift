import Foundation

/// Owns Stage's local source lifetime. The caller must defer cleanup at Stage scope,
/// after all file consumers, rather than at the scope that merely creates the copy.
struct StageWorkspace {
    let toolchain: Toolchain
    private let scratch: URL?

    init(source: Toolchain, preservedBuild: ReusableBuild?,
         prepare: (Toolchain) throws -> Void) throws {
        try RuntimePolicy177.requireSource(source)
        if let preservedBuild {
            try RuntimePolicy177.requireArtifact(preservedBuild)
            toolchain = try Toolchain(root: preservedBuild.workspace)
            scratch = nil
            return // No new workspace, Prepare or Build for an already verified artifact.
        }

        let root = Self.makeScratchURL()
        do {
            let copy = try IsolatedToolchainWorkspace.stage(from: source, to: root)
            try prepare(copy)
            toolchain = copy
            scratch = root
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    static func makeScratchURL() -> URL {
        DataLocation.temporaryDirectory.appendingPathComponent("avpplay-stage-toolchain-\(UUID().uuidString)", isDirectory: true)
    }

    func cleanup() {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }
}
