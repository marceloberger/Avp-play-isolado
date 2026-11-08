import Foundation

public enum FrameGeneration: String, Codable, CaseIterable, Sendable {
    case automatic, off, ahead, between
    public var title: String {
        switch self {
        case .automatic: return "Automático / padrão do Klepton"
        case .off: return "Off"
        case .ahead: return "Ahead"
        case .between: return "In between"
        }
    }
}

public enum SurrealSDKPolicy: String, Codable, CaseIterable, Sendable {
    case verified, bluetooth
}

extension Toolchain {
    /// Returns the verified target-table default only when the checked-in 824 rule is recognizable and
    /// no per-target override exists. Reuse fails closed if Klepton changes that rule.
    public func frameGenerationDefault(for target: String) -> FrameGeneration? {
        guard Recipe.isSafeName(target),
              let source = try? String(contentsOf: root.appendingPathComponent("visionos/targets.py"), encoding: .utf8),
              let defaultRule = try? NSRegularExpression(
                pattern: #"(?m)^\s*t\.setdefault\(\s*.framegen.\s*,\s*.between.\s+if\s+name\s*==\s*.alyx.\s+else\s+.off.\s*\)\s*$"#),
              defaultRule.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) != nil,
              let overrideRule = try? NSRegularExpression(pattern: #"framegen\s*:"#),
              overrideRule.numberOfMatches(in: source, range: NSRange(source.startIndex..., in: source)) == 0 else {
            return nil
        }
        return target == "alyx" ? .between : .off
    }

    public func hasTarget(_ target: String) -> Bool {
        guard !target.isEmpty,
              let source = try? String(contentsOf: root.appendingPathComponent("visionos/targets.py"), encoding: .utf8) else { return false }
        let key = NSRegularExpression.escapedPattern(for: target)
        guard let expression = try? NSRegularExpression(pattern: "(?m)^    \"\(key)\": \\{") else { return false }
        return expression.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) != nil
    }

    /// Klepton 824 accepts a valid store target even when it has no tuned row: `targets.py`
    /// creates an experimental row from the unpacked APK's engine. Keep malformed names blocked.
    public func acceptsBuildTarget(_ target: String) -> Bool {
        hasTarget(target) || DraftRecipe.isGeneric(target)
    }

    public var supportsRuntime824: Bool {
        guard let text = try? String(contentsOf: root.appendingPathComponent("visionos/gen_xcodeproj.py")) else { return false }
        return text.contains("KLEPTON_FRAMEGEN") && text.contains("KLEPTON_SURREAL_SUPPORT")
    }

    public struct CoreModsProfile: Equatable, Sendable {
        public let name: String
        public let target: String
        public let versionCode: Int
        public let versionName: String
    }

    public var coreModsProfiles: [CoreModsProfile] {
        let folder = root.appendingPathComponent("ports/scotland2")
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("avp-profiles.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["schema"] as? Int == 1, let rows = object["profiles"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let name = row["name"] as? String, let target = row["target"] as? String, let code = row["versionCode"] as? Int,
                  let version = row["versionName"] as? String, let prebuilt = row["prebuilt"] as? String,
                  !prebuilt.hasPrefix("/"), !prebuilt.split(separator: "/").contains("..") else { return nil }
            let libs = folder.appendingPathComponent(prebuilt).appendingPathComponent("libs").resolvingSymlinksInPath()
            guard libs.path.hasPrefix(folder.resolvingSymlinksInPath().path + "/"),
                  let files = try? FileManager.default.contentsOfDirectory(atPath: libs.path),
                  files.contains(where: { $0.hasSuffix(".so") }) else { return nil }
            return CoreModsProfile(name: name, target: target, versionCode: code, versionName: version)
        }
    }
    public func coreModsProfile(for recipe: Recipe) -> CoreModsProfile? {
        coreModsProfiles.first { $0.target == recipe.toolchain.target && $0.versionCode == recipe.versionCode && $0.versionName == recipe.versionName }
    }

    /// Used by both local unsigned builds and signed builds; never inferred from shell variables.
    public func runtimeEnvironment(recipe: Recipe, request: InstallRequest, controller: ControllerMode? = nil) throws -> [String:String] {
        let enabled = request.surrealSupport != false
        var environment = try controllerEnvironment(enabled ? (controller ?? request.controllerMode ?? .standard) : .standard)
        let experimental = request.experimental == true && supportsExperimental
        let metalFX = request.metalFX == true && supportsMetalFX
        let prediction = request.xrPrediction == true && supportsXRPrediction
        let switches = (experimental ? Toolchain.experimentalSwitches : [])
            + (metalFX ? [Toolchain.metalFXSwitch] : []) + (prediction ? [Toolchain.xrPredictionSwitch] : [])
        environment["KLEPTON_TEST_ON"] = switches.joined(separator: ",")
        if metalFX && supportsRenderScalePreset {
            environment[Toolchain.renderScaleVariable] = MetalFXResolution.environmentValue(request.resolution)
        }
        if !supportsRuntime824 {
            guard request.coreMods != true,
                  request.frameGeneration == nil || request.frameGeneration == .automatic || request.frameGeneration == .off else {
                throw RecipeError.invalid("This runtime lacks the requested mods/frame generation; select the verified 824 explicitly.")
            }
            return environment
        }
        environment["KLEPTON_SURREAL_SUPPORT"] = enabled ? "1" : "0"
        let sdk = enabled && request.surrealSDK != .bluetooth
        if sdk { try OptionalRuntime824.verifySDK(at: root) }
        environment["KLEPTON_SURREAL_SDK"] = sdk ? "1" : "0"
        switch request.frameGeneration {
        case .automatic:
            // Preserve Klepton's per-target `targets.py` default.
            break
        case .off, .ahead, .between:
            environment["KLEPTON_FRAMEGEN"] = request.frameGeneration?.rawValue
        case nil:
            // Jobs written before build161 stored nil, which historically meant an explicit Off.
            // Keep that meaning when such a Job is resumed; new requests default to `.automatic`.
            environment["KLEPTON_FRAMEGEN"] = FrameGeneration.off.rawValue
        }
        let mods = request.coreMods == true
        guard !mods || coreModsProfile(for: recipe) != nil else {
            throw RecipeError.invalid("No verified mod profile/prebuilt for this exact game version. No build started.")
        }
        environment["KLEPTON_SCOTLAND2"] = mods ? "1" : "0"
        if mods, let profile = coreModsProfile(for: recipe) {
            environment["SC2_BUILD_MODE"] = "release"
            environment["SC2_TEST_SET"] = "coremods"
            environment["SC2_GAME_PROFILE"] = profile.name
        }
        return environment
    }
}

extension ToolchainPackager {
    /// New operations require verified 850. Historical choices remain data only and are never rewritten.
    public func selectedToolchain(for recipe: Recipe, choices: ToolchainChoices) -> Toolchain? {
        let resolved = KleptonRecipeCompatibility.resolve(recipe)
        guard let runtime = verified850(), runtime.acceptsBuildTarget(resolved.toolchain.target),
              resolved.toolchain.minCommit.isEmpty || runtime.satisfies(minCommit: resolved.toolchain.minCommit) else { return nil }
        return runtime
    }

    /// Historical 824 lookup for inspection; it does not authorize a new operation.
    public func verified824() -> Toolchain? {
        installed().first { OptionalRuntime824.hasVerifiedReceipt(for: $0) }
    }

    /// Legacy API name retained for callers; selection now requires verified 850 and recipe compatibility.
    public func build158Toolchain(for recipe: Recipe) -> Toolchain? {
        selectedToolchain(for: recipe, choices: ToolchainChoices())
    }

    /// The functional default follows the mandatory 850 policy.
    public func functionalDefault() -> Toolchain? {
        verified850()
    }
    public func defaultForRecipe(_ recipe: Recipe, fallback: Toolchain? = nil) -> Toolchain? {
        selectedToolchain(for: recipe, choices: ToolchainChoices())
    }

}

public enum OptionalRuntime824 {
    public static let archiveName = "klepton-toolchain-824-a61188d.tar.gz"
    public static let archiveSHA256 = "e1576bb71256587f367b0d64b268dc5668e30629aec0c6268e7d74d4a6adce12"
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
        guard toolchain.version() == 824, toolchain.commit() == "a61188d", !toolchain.isModified,
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

    /// Rehashes the complete installed 824 payload before an experimental recipe uses it.
    /// The receipt file itself is excluded; all 2,109 package files must match exactly.
    @discardableResult
    public static func verifyFullIntegrity(of toolchain: Toolchain) throws -> Int {
        guard hasVerifiedReceipt(for: toolchain), toolchain.satisfies(minCommit: "a61188d") else {
            throw RecipeError.invalid("Klepton 824 não tem recibo válido de origem/versão; compilação experimental bloqueada.")
        }
        let receiptURL = toolchain.root.appendingPathComponent(".isolated-source-sha256.json")
        guard let data = try? Data(contentsOf: receiptURL),
              let expected = try? JSONDecoder().decode([String: String].self, from: data),
              expected.count == 2109,
              expected.allSatisfy({ Recipe.isSafeRelativePath($0.key) && $0.value.count == 64 && $0.value.allSatisfy(\.isHexDigit) }) else {
            throw RecipeError.invalid("Recibo Klepton 824 inválido: a lista integral de 2.109 hashes está ausente ou malformada.")
        }
        var actual = Set<String>()
        let rootPath = toolchain.root.standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(at: toolchain.root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: []) else {
            throw RecipeError.invalid("Não foi possível enumerar os arquivos do Klepton 824.")
        }
        for case let url as URL in enumerator {
            if url.standardizedFileURL == receiptURL.standardizedFileURL { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true || values.isSymbolicLink == true else { continue }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolved.hasPrefix(rootPath + "/") else {
                throw RecipeError.invalid("Link Klepton 824 aponta para fora do runtime: \(url.lastPathComponent)")
            }
            let relative = String(url.standardizedFileURL.path.dropFirst(rootPath.count + 1))
            guard Recipe.isSafeRelativePath(relative), let wanted = expected[relative] else {
                throw RecipeError.invalid("Arquivo não registrado no recibo Klepton 824: \(url.lastPathComponent)")
            }
            actual.insert(relative)
            guard try Hashing.sha256(of: url).lowercased() == wanted.lowercased() else {
                throw RecipeError.invalid("SHA-256 divergente no Klepton 824: \(url.lastPathComponent)")
            }
        }
        guard actual == Set(expected.keys) else {
            throw RecipeError.invalid("Faltam arquivos do pacote Klepton 824; integridade completa recusada.")
        }
        return actual.count
    }
    /// Stage only receipt-listed package files. Legacy prepared games in the installed root
    /// are preserved but never copied or executed. The isolated result still passes the
    /// exact 2,109-file integrity check before any preparation or build command runs.
    public static func stageVerifiedPayload(from toolchain: Toolchain, to destination: URL) throws {
        guard hasVerifiedReceipt(for: toolchain) else {
            throw RecipeError.invalid("Klepton 824 sem recibo válido; restaure o pacote verificado antes de Prepare ou Build only.")
        }
        let receipt = toolchain.root.appendingPathComponent(".isolated-source-sha256.json")
        let data = try Data(contentsOf: receipt)
        let expected = try JSONDecoder().decode([String: String].self, from: data)
        guard expected.count == 2109,
              expected.allSatisfy({ Recipe.isSafeRelativePath($0.key) && $0.value.count == 64 && $0.value.allSatisfy(\.isHexDigit) }) else {
            throw RecipeError.invalid("Recibo Klepton 824 inválido: são necessários 2.109 hashes válidos.")
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
                    throw RecipeError.invalid("Arquivo Klepton 824 ausente, alterado ou inseguro: \(path). Restaure o pacote verificado antes de Prepare ou Build only.")
                }
                let target = destination.appendingPathComponent(path)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                // Dereference safe links so the staged payload cannot depend on legacy extras.
                try fm.copyItem(at: source.resolvingSymlinksInPath(), to: target)
            }
            try data.write(to: destination.appendingPathComponent(receipt.lastPathComponent), options: .atomic)
            _ = try verifyFullIntegrity(of: Toolchain(root: destination))
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
        let destination = packager.root.appendingPathComponent("824-a61188d")
        let receipt = destination.appendingPathComponent(".isolated-source-sha256.json")
        if FileManager.default.fileExists(atPath: destination.path) {
            guard let data = try? Data(contentsOf: receipt),
                  let hashes = try? JSONDecoder().decode([String:String].self,from:data) else { throw PackageError.contentMismatch }
            for (path,hash) in hashes {
                guard try Hashing.sha256(of: destination.appendingPathComponent(path)) == hash else { throw PackageError.contentMismatch }
            }
        }
        let toolchain = try packager.install(archive: archive)
        guard toolchain.commit() == "a61188d", toolchain.version() == 824 else { throw PackageError.contentMismatch }
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

/// Makes a fresh, verified workspace for operations that need Klepton's prepared APK tree.
/// The installed 824/850 roots are never prepared in place; 850 always receives TLS168 in the copy.
public enum IsolatedToolchainWorkspace {
    @discardableResult
    public static func stage(from source: Toolchain, to destination: URL) throws -> Toolchain {
        try RuntimePolicy177.requireSource(source)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw BuildOnlyError.workspaceExists(destination)
        }
        if source.version() == 850 && source.commit() == "cc2856c" {
            _ = try OptionalRuntime850.verifyFullIntegrity(of: source)
            try OptionalRuntime850.stageVerifiedPayload(from: source, to: destination)
        } else if source.version() == 824 && source.commit() == "a61188d" {
            _ = try OptionalRuntime824.verifyFullIntegrity(of: source)
            try OptionalRuntime824.stageVerifiedPayload(from: source, to: destination)
        } else {
            try FileManager.default.copyItem(at: source.root, to: destination)
        }
        return try Toolchain(root: destination)
    }
}
