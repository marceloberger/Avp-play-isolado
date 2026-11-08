import Foundation

public enum OptionalRuntime850 {
    public static let archiveName = "klepton-toolchain-850-cc2856c.tar.gz"
    public static let archiveSHA256 = "7aadea1de617de88309bfd04b65d9fc873b396c6e0405e8ade7e064623925bc9"
    public static let sdkArchiveSHA256 = "371361f4ff566abbf07fa19c4da80c614b2c21b4527c7dc88100f876e86a6df8"
    public static let sdkCommit = "a42deb007c7f12afb543b235b75464e86e00125a"
    public static let sdkName = "surreal_interactive_openxr_framework"
    public static let sdkHashes = [
        "Info.plist":"9ee646fd4acd5474efb1b5026aadbb8c54b12a5a43769db3e64792985c8bbe2e",
        "xros-arm64/\(sdkName).framework/\(sdkName)":"6f1770cdd38824a4fdf756325cd6fc21b0e77780aa0dd57122297ceef29b81f1",
        "xros-arm64-simulator/\(sdkName).framework/\(sdkName)":"5f234707ff468cf1345670c134654e3da3e65aaafd835b24c33de2dbd05b04e0"
    ]
    /// Require evidence created only after the bundled archive passed its SHA-256 check.
    /// The manifest hash binds the installed runtime to that receipt; missing/modified receipts fail closed.
    public static func hasVerifiedReceipt(for toolchain: Toolchain) -> Bool {
        guard toolchain.version() == 850, toolchain.commit() == "cc2856c", !toolchain.isModified,
              let data = try? Data(contentsOf: toolchain.root.appendingPathComponent(".isolated-source-sha256.json")),
              let hashes = try? JSONDecoder().decode([String:String].self, from: data),
              !hashes.isEmpty else { return false }
        let critical = ["toolchain.json", "Makefile", "visionos/run.sh", "visionos/targets.py",
                        "visionos/gen_xcodeproj.py", "visionos/Sources/kl_app.c"]
        return critical.allSatisfy { path in
            guard let expected = hashes[path] else { return false }
            return (try? Hashing.sha256(of: toolchain.root.appendingPathComponent(path))) == expected
        }
    }

    /// Rehashes the complete installed 850 payload before an experimental recipe uses it.
    /// The receipt file itself is excluded; all 2,109 package files must match exactly.
    @discardableResult
    public static func verifyFullIntegrity(of toolchain: Toolchain) throws -> Int {
        guard hasVerifiedReceipt(for: toolchain), toolchain.satisfies(minCommit: "cc2856c") else {
            throw RecipeError.invalid("Klepton 850 não tem recibo válido de origem/versão; compilação experimental bloqueada.")
        }
        let receiptURL = toolchain.root.appendingPathComponent(".isolated-source-sha256.json")
        guard let data = try? Data(contentsOf: receiptURL),
              let expected = try? JSONDecoder().decode([String: String].self, from: data),
              expected.count == 2116,
              expected.allSatisfy({ Recipe.isSafeRelativePath($0.key) && $0.value.count == 64 && $0.value.allSatisfy(\.isHexDigit) }) else {
            throw RecipeError.invalid("Recibo Klepton 850 inválido: a lista integral de 2.116 hashes está ausente ou malformada.")
        }
        var actual = Set<String>()
        let rootPath = toolchain.root.standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(at: toolchain.root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: []) else {
            throw RecipeError.invalid("Não foi possível enumerar os arquivos do Klepton 850.")
        }
        for case let url as URL in enumerator {
            if url.standardizedFileURL == receiptURL.standardizedFileURL { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true || values.isSymbolicLink == true else { continue }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolved.hasPrefix(rootPath + "/") else {
                throw RecipeError.invalid("Link Klepton 850 aponta para fora do runtime: \(url.lastPathComponent)")
            }
            let relative = String(url.standardizedFileURL.path.dropFirst(rootPath.count + 1))
            guard Recipe.isSafeRelativePath(relative), let wanted = expected[relative] else {
                throw RecipeError.invalid("Arquivo não registrado no recibo Klepton 850: \(url.lastPathComponent)")
            }
            actual.insert(relative)
            guard try Hashing.sha256(of: url).lowercased() == wanted.lowercased() else {
                throw RecipeError.invalid("SHA-256 divergente no Klepton 850: \(url.lastPathComponent)")
            }
        }
        guard actual == Set(expected.keys) else {
            throw RecipeError.invalid("Faltam arquivos do pacote Klepton 850; integridade completa recusada.")
        }
        return actual.count
    }
    /// Stage only receipt-listed package files. Legacy prepared games in the installed root
    /// are preserved but never copied or executed. The isolated result still passes the
    /// exact 2,109-file integrity check before any preparation or build command runs.
    public static func stageVerifiedPayload(from toolchain: Toolchain, to destination: URL) throws {
        guard hasVerifiedReceipt(for: toolchain) else {
            throw RecipeError.invalid("Klepton 850 sem recibo válido; restaure o pacote verificado antes de Prepare ou Build only.")
        }
        let receipt = toolchain.root.appendingPathComponent(".isolated-source-sha256.json")
        let data = try Data(contentsOf: receipt)
        let expected = try JSONDecoder().decode([String: String].self, from: data)
        guard expected.count == 2116,
              expected.allSatisfy({ Recipe.isSafeRelativePath($0.key) && $0.value.count == 64 && $0.value.allSatisfy(\.isHexDigit) }) else {
            throw RecipeError.invalid("Recibo Klepton 850 inválido: são necessários 2.116 hashes válidos.")
        }
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else { throw BuildOnlyError.workspaceExists(destination) }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        do {
            let sourceRoot = toolchain.root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
            for (path, hash) in expected.sorted(by: { $0.key < $1.key }) {
                try Task.checkCancellation()
                let source = toolchain.root.appendingPathComponent(path)
                guard source.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(sourceRoot),
                      (try? source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                      try Hashing.sha256(of: source).lowercased() == hash.lowercased() else {
                    throw RecipeError.invalid("Arquivo Klepton 850 ausente, alterado ou inseguro: \(path). Restaure o pacote verificado antes de Prepare ou Build only.")
                }
                let target = destination.appendingPathComponent(path)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                // Dereference safe links so the staged payload cannot depend on legacy extras.
                try fm.copyItem(at: source.resolvingSymlinksInPath(), to: target)
            }
            try data.write(to: destination.appendingPathComponent(receipt.lastPathComponent), options: .atomic)
            _ = try verifyFullIntegrity(of: Toolchain(root: destination))
            try ExperimentalTLS170.apply(to: destination)
        } catch {
            try? fm.removeItem(at: destination)
            throw error
        }
    }

    public static func verifySDK(at toolchain: URL) throws {
        let framework = toolchain.appendingPathComponent("visionos/Frameworks/\(sdkName).xcframework")
        for (file,hash) in sdkHashes {
            guard (try? Hashing.sha256(of: framework.appendingPathComponent(file))) == hash else {
                throw RecipeError.invalid("Surreal SDK missing or corrupt: \(file). Restore the verified optional SDK or explicitly select Bluetooth fallback.")
            }
        }
    }
    /// Explicit UI operation only. No call from startup, Probe, Resume or game construction.
    public static func install(resources: URL, packager: ToolchainPackager) throws -> Toolchain {
        let archive = resources.appendingPathComponent(archiveName)
        let sdk = resources.appendingPathComponent("surreal-sdk.tar.gz")
        guard try Hashing.sha256(of: archive) == archiveSHA256,
              try Hashing.sha256(of: sdk) == sdkArchiveSHA256 else { throw PackageError.checksumMismatch }
        let destination = packager.root.appendingPathComponent("850-cc2856c")
        let receipt = destination.appendingPathComponent(".isolated-source-sha256.json")
        if FileManager.default.fileExists(atPath: destination.path) {
            guard let data = try? Data(contentsOf: receipt),
                  let hashes = try? JSONDecoder().decode([String:String].self,from:data) else { throw PackageError.contentMismatch }
            for (path,hash) in hashes {
                guard try Hashing.sha256(of: destination.appendingPathComponent(path)) == hash else { throw PackageError.contentMismatch }
            }
        }
        let toolchain = try packager.install(archive: archive)
        guard toolchain.commit() == "cc2856c", toolchain.version() == 850 else { throw PackageError.contentMismatch }
        if (try? verifySDK(at: toolchain.root)) != nil { return toolchain }
        let temporary = DataLocation.temporaryDirectory.appendingPathComponent("avp156-sdk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        _ = try Toolchain.capture(["/usr/bin/tar","-xzf",sdk.path,"-C",temporary.path])
        let source = temporary.appendingPathComponent("SwiftSDKBinary-\(sdkCommit)")
        let target = toolchain.root.appendingPathComponent("visionos/Frameworks/\(sdkName).xcframework")
        // Never replace an unknown preexisting SDK; corruption requires review.
        guard !FileManager.default.fileExists(atPath: target.path) else { throw PackageError.contentMismatch }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source.appendingPathComponent("\(sdkName).xcframework"), to: target)
        try FileManager.default.copyItem(at: source.appendingPathComponent("LICENSE"),to: target.appendingPathComponent("LICENSE"))
        try verifySDK(at: toolchain.root)
        try Data().write(to: target.appendingPathComponent(".klepton-fetched-\(sdkCommit)"))
        var hashes: [String:String] = [:]
        if let files = FileManager.default.enumerator(at:toolchain.root,includingPropertiesForKeys:[.isRegularFileKey]) {
            for case let file as URL in files where (try file.resourceValues(forKeys:[.isRegularFileKey])).isRegularFile == true {
                let rootPath = toolchain.root.resolvingSymlinksInPath().standardizedFileURL.path
                let filePath = file.resolvingSymlinksInPath().standardizedFileURL.path
                guard filePath.hasPrefix(rootPath + "/") else { throw PackageError.contentMismatch }
                hashes[String(filePath.dropFirst(rootPath.count+1))] = try Hashing.sha256(of:file)
            }
        }
        try JSONEncoder().encode(hashes).write(to:receipt,options:.atomic)
        return toolchain
    }
}


extension ToolchainPackager {
    public func verified850() -> Toolchain? {
        installed().first { OptionalRuntime850.hasVerifiedReceipt(for: $0) }
    }
    public func build170Toolchain(for recipe: Recipe) -> Toolchain? {
        guard let runtime = verified850(), runtime.acceptsBuildTarget(recipe.toolchain.target),
              recipe.toolchain.minCommit.isEmpty || runtime.satisfies(minCommit: recipe.toolchain.minCommit) else { return nil }
        return runtime
    }
}
