import Foundation

/// Local provisioning uses the existing Apple identity. Manual Xcode UI remains an explicit recovery action.
public struct ProfileProvisioning: Codable, Sendable {
    public var bundle: String
    public var team: String
    public var device: String
    public var identity: String
    public var entitlements: Data

    public struct Required: Error, CustomStringConvertible {
        public let request: URL
        public var description: String {
            "Perfil compatível ainda ausente. Build preservado. Confira a conta Apple na tela Setup e use Resume para tentar novamente. A configuração manual no Xcode permanece disponível como recuperação. [PROFILE_REQUIRED:\(Data(request.path.utf8).base64EncodedString())]"
        }
    }
    public static func requestURL(in failure: String) -> URL? {
        guard let a = failure.range(of: "[PROFILE_REQUIRED:"), let b = failure[a.upperBound...].firstIndex(of: "]"),
              let data = Data(base64Encoded: String(failure[a.upperBound..<b])),
              let path = String(data: data, encoding: .utf8), path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path)
    }
    public static func userMessage(_ failure: String) -> String {
        guard let marker = failure.range(of: "[PROFILE_REQUIRED:") else { return failure }
        return String(failure[..<marker.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public func save(under root: URL) throws -> URL {
        let url = root.appendingPathComponent("\(UUID().uuidString).json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        return url
    }

    /// Provisions a separate minimal visionOS app with the existing Keychain identity.
    /// This command only builds locally; it never installs or launches on a device.
    public func provisionAutomatically(root: URL, report: @Sendable (String) -> Void = { _ in },
        run: ((BuildOnlyCommand, URL) throws -> Int32)? = nil) throws {
        guard SigningWarmUp.existingIdentities(team: team).contains(identity) else {
            throw ToolchainError.signingBlocked("Certificado Apple Development existente indisponível. Build preservado.")
        }
        let project = try openInXcode(approved: true, root: root, open: { _ in })
        let directory = project.deletingLastPathComponent()
        let file = project.appendingPathComponent("project.pbxproj")
        var text = try String(contentsOf: file)
        text = text.replacingOccurrences(of: "buildPhases = ();", with: "buildPhases = (A00000000000000000000010);")
        text = text.replacingOccurrences(of: "children = (A00000000000000000000009);", with: "children = (A00000000000000000000009, A00000000000000000000011);")
        text = text.replacingOccurrences(of: "}; rootObject =", with: """
        A00000000000000000000010 = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (A00000000000000000000012); runOnlyForDeploymentPostprocessing = 0; };
        A00000000000000000000011 = {isa = PBXFileReference; lastKnownFileType = sourcecode.c.c; path = main.c; sourceTree = "<group>"; };
        A00000000000000000000012 = {isa = PBXBuildFile; fileRef = A00000000000000000000011; };
        }; rootObject =
        """)
        try text.write(to: file, atomically: true, encoding: .utf8)
        try "int main(void) { return 0; }\n".write(to: directory.appendingPathComponent("main.c"), atomically: true, encoding: .utf8)
        let command = Self.automaticCommand(project: project, device: device)
        let log = directory.appendingPathComponent("provisioning.log")
        report("Configurando perfil visionOS com certificado Apple Development existente; log: \(log.path)")
        try Task.checkCancellation()
        let status = try (run ?? BuildOnlyPipeline.runProcessForTesting)(command, log)
        try Task.checkCancellation()
        guard status == 0 else {
            throw ToolchainError.signingBlocked("Provisionamento Apple falhou (código \(status)). Confira a conta Apple na tela Setup e retome o Job. Build preservado. Log: \(log.path)")
        }
    }

    static func automaticCommand(project: URL, device: String) -> BuildOnlyCommand {
        BuildOnlyCommand(executable: URL(fileURLWithPath: "/usr/bin/xcodebuild"),
            arguments: ["-project", project.path, "-scheme", "ProfileSetup", "-configuration", "Debug",
                        "-sdk", "xros", "-destination", "id=" + device,
                        "-allowProvisioningUpdates", "-allowProvisioningDeviceRegistration", "build"],
            directory: project.deletingLastPathComponent(),
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory()])
    }

    /// No xcodebuild, login, certificate generation, or provisioning request is run by this method.
    /// Xcode's Signing UI lets the user complete automatic provisioning with their existing account.
    @discardableResult
    public func openInXcode(approved: Bool, root: URL,
                            open: ((URL) throws -> Void)? = nil) throws -> URL {
        guard approved else { throw CancellationError() }
        guard SigningRecord.isSafeBundleId(bundle), team.count == 10, team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
              identity.count == 40, identity.allSatisfy(\.isHexDigit) else {
            throw RecipeError.invalid("Dados de assinatura inválidos")
        }
        try Task.checkCancellation()
        let directory = root.appendingPathComponent(UUID().uuidString)
        let project = directory.appendingPathComponent("ProfileSetup.xcodeproj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try entitlements.write(to: directory.appendingPathComponent("Signing.entitlements"))
        let text = """
        // !$*UTF8*$!
        { archiveVersion = 1; classes = {}; objectVersion = 56; objects = {
        A00000000000000000000001 = {isa = PBXProject; buildConfigurationList = A00000000000000000000002; compatibilityVersion = "Xcode 14.0"; mainGroup = A00000000000000000000003; productRefGroup = A00000000000000000000009; targets = (A00000000000000000000004); attributes = {TargetAttributes = {A00000000000000000000004 = {DevelopmentTeam = \(team); ProvisioningStyle = Automatic; }; }; }; };
        A00000000000000000000002 = {isa = XCConfigurationList; buildConfigurations = (A00000000000000000000005); defaultConfigurationName = Debug; };
        A00000000000000000000003 = {isa = PBXGroup; children = (A00000000000000000000009); sourceTree = "<group>"; };
        A00000000000000000000004 = {isa = PBXNativeTarget; buildConfigurationList = A00000000000000000000006; buildPhases = (); buildRules = (); dependencies = (); name = ProfileSetup; productName = ProfileSetup; productReference = A00000000000000000000008; productType = "com.apple.product-type.application"; };
        A00000000000000000000005 = {isa = XCBuildConfiguration; buildSettings = {}; name = Debug; };
        A00000000000000000000006 = {isa = XCConfigurationList; buildConfigurations = (A00000000000000000000007); defaultConfigurationName = Debug; };
        A00000000000000000000007 = {isa = XCBuildConfiguration; name = Debug; buildSettings = {CODE_SIGN_STYLE = Automatic; DEVELOPMENT_TEAM = \(team); PRODUCT_BUNDLE_IDENTIFIER = "\(bundle)"; CODE_SIGN_IDENTITY = "\(identity)"; CODE_SIGN_ENTITLEMENTS = Signing.entitlements; SDKROOT = xros; SUPPORTED_PLATFORMS = xros; TARGETED_DEVICE_FAMILY = 7; GENERATE_INFOPLIST_FILE = YES; PRODUCT_NAME = ProfileSetup; }; };
        A00000000000000000000008 = {isa = PBXFileReference; explicitFileType = wrapper.application; path = ProfileSetup.app; sourceTree = BUILT_PRODUCTS_DIR; };
        A00000000000000000000009 = {isa = PBXGroup; children = (A00000000000000000000008); name = Products; sourceTree = "<group>"; };
        }; rootObject = A00000000000000000000001; }
        """
        try text.write(to: project.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)
        try "Projeto somente para Signing & Capabilities. Não execute Build/Run. Bundle ID do jogo preservado; use apenas o certificado existente. Após obter o perfil, volte ao AVP Play e use Resume."
            .write(to: directory.appendingPathComponent("LEIA-ME.txt"), atomically: true, encoding: .utf8)
        if let open { try open(project) }
        else {
            guard SigningWarmUp.existingIdentities(team: team).contains(identity) else {
                throw ToolchainError.signingBlocked("O certificado existente não está mais disponível. Nenhum certificado será criado.")
            }
            _ = try ApkUnpacker.run(["/usr/bin/open", "-a", "Xcode", project.path])
        }
        return project
    }
}
