import Foundation
import CryptoKit

/// Signs a copy with an existing identity/profile. No compiler, project generator or certificate creation.
public enum ExistingAppSigner {
    public struct Profile: @unchecked Sendable {
        public var path: URL
        public var data: Data
        public var values: [String: Any]
    }
    public struct Plan: Sendable {
        public var profile: URL
        public var profileData: Data
        public var entitlements: Data
        public var expires: Date
    }
    public struct SignedApp: Sendable { public var app: URL; public var expires: Date }
    static func permits(_ allowed: Any, _ requested: Any) -> Bool {
        if let a = allowed as? String, let b = requested as? String {
            let pattern = "^" + NSRegularExpression.escapedPattern(for: a).replacingOccurrences(of: "\\*", with: ".*") + "$"
            return b.range(of: pattern, options: .regularExpression) != nil
        }
        if let a = allowed as? [Any], let b = requested as? [Any] { return b.allSatisfy { value in a.contains { permits($0, value) } } }
        return (allowed as? NSObject)?.isEqual(requested) == true
    }

    public static func plan(profiles: [Profile], team: String, bundle: String, device: String,
                            identity: String, requested: [String: Any], free: Bool, now: Date = Date()) throws -> Plan {
        for profile in profiles.sorted(by: { ($0.values["ExpirationDate"] as? Date ?? .distantPast) > ($1.values["ExpirationDate"] as? Date ?? .distantPast) }) {
            let v = profile.values
            let prefix = (v["ApplicationIdentifierPrefix"] as? [String])?.first ?? team
            guard (v["TeamIdentifier"] as? [String])?.contains(team) == true,
                  let expires = v["ExpirationDate"] as? Date, expires > now,
                  (v["CreationDate"] as? Date ?? .distantPast) <= now,
                  (v["Platform"] as? [String])?.contains(where: { ["xrOS", "visionOS", "XROS"].contains($0) }) == true,
                  (v["ProvisionedDevices"] as? [String])?.contains(device) == true,
                  let capabilities = v["Entitlements"] as? [String: Any],
                  let appID = capabilities["application-identifier"], permits(appID, "\(prefix).\(bundle)"),
                  let certificates = v["DeveloperCertificates"] as? [Data],
                  certificates.contains(where: { Insecure.SHA1.hash(data: $0).map { String(format: "%02X", $0) }.joined() == identity.uppercased() }) else { continue }
            var wanted = requested
            // Same Personal Team entitlement policy as Klepton's existing generator; no native code change.
            if free {
                wanted.removeValue(forKey: "com.apple.developer.kernel.extended-virtual-addressing")
                wanted.removeValue(forKey: "com.apple.developer.low-latency-streaming")
            }
            func expand(_ text: String) -> String {
                text.replacingOccurrences(of: "$(AppIdentifierPrefix)", with: prefix + ".")
                    .replacingOccurrences(of: "$(PRODUCT_BUNDLE_IDENTIFIER)", with: bundle)
            }
            for (key, value) in wanted {
                if let s = value as? String { wanted[key] = expand(s) }
                if let a = value as? [String] { wanted[key] = a.map(expand) }
            }
            guard wanted.allSatisfy({ key, value in capabilities[key].map { permits($0, value) } ?? false }) else { continue }
            wanted["application-identifier"] = "\(prefix).\(bundle)"
            wanted["com.apple.developer.team-identifier"] = team
            if let debugging = capabilities["get-task-allow"] { wanted["get-task-allow"] = debugging }
            return Plan(profile: profile.path, profileData: profile.data,
                        entitlements: try PropertyListSerialization.data(fromPropertyList: wanted, format: .xml, options: 0), expires: expires)
        }
        throw LocalAPKVariantError.invalidRecord("O build está preservado, mas falta um perfil Apple existente, válido para esta equipe, Bundle ID, certificado, headset e permissões. Configure o perfil no Xcode; não é necessário recompilar o jogo. Nenhum certificado será criado automaticamente.")
    }

    static func select(profiles: [Profile], identities: [String], team: String, bundle: String,
                       device: String, requested: [String: Any], free: Bool) throws -> (plan: Plan, identity: String) {
        var candidates: [(plan: Plan, identity: String)] = []
        for identity in identities {
            if let plan = try? plan(profiles: profiles, team: team, bundle: bundle, device: device,
                                    identity: identity, requested: requested, free: free) { candidates.append((plan, identity)) }
        }
        guard let selected = candidates.max(by: { $0.plan.expires < $1.plan.expires }) else {
            throw ToolchainError.signingBlocked("Nenhum perfil existente compatível com os certificados disponíveis.")
        }
        return selected
    }

    static func profiles() -> [Profile] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = ["Library/Developer/Xcode/UserData/Provisioning Profiles", "Library/MobileDevice/Provisioning Profiles"]
        return roots.flatMap { folder -> [Profile] in
            let files = (try? FileManager.default.contentsOfDirectory(at: home.appendingPathComponent(folder), includingPropertiesForKeys: nil)) ?? []
            return files.filter { ["mobileprovision", "provisionprofile"].contains($0.pathExtension) }.compactMap { path in
                guard let data = try? Data(contentsOf: path),
                      let values = try? ProvisioningProfileDecoder.decode(data),
                      values["UUID"] as? String != nil,
                      values["TeamIdentifier"] as? [String] != nil,
                      values["ExpirationDate"] as? Date != nil,
                      values["Entitlements"] as? [String: Any] != nil,
                      values["DeveloperCertificates"] as? [Data] != nil else { return nil }
                return Profile(path: path, data: data, values: values)
            }
        }
    }

    static func signingTargets(_ app: URL) throws -> [URL] {
        guard let walker = FileManager.default.enumerator(at: app, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return [] }
        var targets: Set<URL> = []
        for case let file as URL in walker {
            if ["app", "appex", "xpc"].contains(file.pathExtension) {
                throw LocalAPKVariantError.invalidRecord("O app contém um bundle adicional que exige perfil próprio; reutilização automática recusada.")
            }
            guard (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { continue }
            if file.pathExtension == "framework" { targets.insert(file) }
            if file.pathExtension == "dylib", !file.pathComponents.contains(where: { $0.hasSuffix(".framework") }) { targets.insert(file) }
        }
        return targets.sorted { $0.pathComponents.count > $1.pathComponents.count || ($0.pathComponents.count == $1.pathComponents.count && $0.path < $1.path) } + [app]
    }

    static func run(_ arguments: [String], log: URL) throws {
        try Task.checkCancellation()
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: log); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: Data(("\n" + arguments.joined(separator: " ") + "\n").utf8))
        let p = Process(); p.executableURL = URL(fileURLWithPath: arguments[0]); p.arguments = Array(arguments.dropFirst())
        p.standardOutput = handle; p.standardError = handle; p.standardInput = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        try handle.write(contentsOf: Data("\n[exit \(p.terminationStatus)]\n".utf8))
        try Task.checkCancellation()
        guard p.terminationStatus == 0 else { throw ToolchainError.buildFailed(log: log, hint: "Falha ao assinar o app existente; nenhuma recompilação foi iniciada.") }
    }

    public static func sign(_ artifact: ReusableBuild, team: String, device: Device, outputRoot: URL,
                            destinationBundleID: String? = nil,
                            preserveAllRequestedEntitlements: Bool = false,
                            automaticProvisioning: Bool = false,
                            report: @Sendable (String) -> Void = { _ in }) throws -> SignedApp {
        try RuntimePolicy177.requireArtifact(artifact)
        report("Runtime efetivo: " + RuntimePolicy177.label)
        let identities = SigningWarmUp.existingIdentities(team: team)
        guard var identity = identities.first else {
            throw ToolchainError.signingBlocked("Não há identidade Apple Development válida já configurada para a equipe \(team). O build foi preservado; nenhum certificado foi criado.")
        }
        let actual = try ReusableBuild.infoPlist(artifact.app.appendingPathComponent("Info.plist"))
        guard let realBundle = actual["CFBundleIdentifier"] as? String, realBundle == artifact.bundleID else {
            throw ToolchainError.signingBlocked("Bundle ID real diverge do build preservado. Nenhuma alteração automática será feita.")
        }
        let destination = destinationBundleID ?? realBundle
        if destination != realBundle {
            // Reject nested apps/extensions before preparing any changed copy.
            _ = try signingTargets(artifact.app)
            guard let marker = realBundle.range(of: ".target.", options: .backwards) else {
                throw ToolchainError.signingBlocked("Alvo do Bundle ID original não identificado.")
            }
            try LocalBundleIdentity(destination: destination, source: realBundle)
                .validate(target: String(realBundle[marker.upperBound...]))
        }
        let requested = try ReusableBuild.infoPlist(artifact.workspace.appendingPathComponent("visionos/Klepton.entitlements"))
        let plan: Plan
        do {
            let selected = try select(profiles: profiles(), identities: identities, team: team,
                                      bundle: destination, device: device.udid, requested: requested, free: !preserveAllRequestedEntitlements && AppleTeams.isFree(team))
            plan = selected.plan; identity = selected.identity
        } catch {
            var effective = requested
            if !preserveAllRequestedEntitlements && AppleTeams.isFree(team) {
                effective.removeValue(forKey: "com.apple.developer.kernel.extended-virtual-addressing")
                effective.removeValue(forKey: "com.apple.developer.low-latency-streaming")
            }
            let request = ProfileProvisioning(bundle: destination, team: team, device: device.udid, identity: identity,
                entitlements: try PropertyListSerialization.data(fromPropertyList: effective, format: .xml, options: 0))
            let url = try request.save(under: outputRoot.appendingPathComponent("profile-requests"))
            guard automaticProvisioning else { throw ProfileProvisioning.Required(request: url) }
            do {
                try request.provisionAutomatically(root: outputRoot.appendingPathComponent("profile-setup"), report: report)
                let selected = try select(profiles: profiles(), identities: identities, team: team,
                    bundle: destination, device: device.udid, requested: requested,
                    free: !preserveAllRequestedEntitlements && AppleTeams.isFree(team))
                plan = selected.plan; identity = selected.identity
            } catch {
                throw ToolchainError.signingBlocked("\(error) \(ProfileProvisioning.Required(request: url))")
            }
        }
        report("Assinatura: perfil \(plan.profile.lastPathComponent), Bundle ID \(destination), equipe \(team), válido até \(plan.expires). Reutilizando certificado existente.")
        _ = try SigningWarmUp.run(identity: identity)
        try Task.checkCancellation()
        let folder = outputRoot.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent(artifact.app.lastPathComponent)
        try FileManager.default.copyItem(at: artifact.app, to: copy)
        try artifact.verifyCopy(copy)
        try adaptIdentity(of: copy, artifact: artifact, destination: destination)
        try plan.profileData.write(to: copy.appendingPathComponent("embedded.mobileprovision"), options: .atomic)
        let entitlements = folder.appendingPathComponent("entitlements.plist")
        try plan.entitlements.write(to: entitlements, options: .atomic)
        let log = folder.appendingPathComponent("sign-existing.log")
        for target in try signingTargets(copy) {
            var arguments = ["/usr/bin/codesign", "--force", "--sign", identity, "--timestamp=none"]
            if target == copy { arguments += ["--identifier", destination, "--entitlements", entitlements.path] }
            try run(arguments + [target.path], log: log)
        }
        try run(["/usr/bin/codesign", "--verify", "--deep", "--strict", copy.path], log: log)
        return SignedApp(app: copy, expires: plan.expires)
    }

    /// Must run only after byte-for-byte copy verification; the source remains immutable.
    static func adaptIdentity(of copy: URL, artifact: ReusableBuild, destination: String) throws {
        guard copy.standardizedFileURL.resolvingSymlinksInPath() != artifact.app.standardizedFileURL.resolvingSymlinksInPath() else {
            throw ToolchainError.signingBlocked("O artefato original não pode ser modificado.")
        }
        var info = try ReusableBuild.infoPlist(copy.appendingPathComponent("Info.plist"))
        guard info["CFBundleIdentifier"] as? String == artifact.bundleID else {
            throw ToolchainError.signingBlocked("A cópia não corresponde à identidade verificada.")
        }
        if destination == artifact.bundleID { return }
        guard let marker = artifact.bundleID.range(of: ".target.", options: .backwards) else {
            throw ToolchainError.signingBlocked("Alvo não identificado.")
        }
        try LocalBundleIdentity(destination: destination, source: artifact.bundleID)
            .validate(target: String(artifact.bundleID[marker.upperBound...]))
        _ = try signingTargets(copy)
        info["CFBundleIdentifier"] = destination
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: copy.appendingPathComponent("Info.plist"), options: .atomic)
    }
}
