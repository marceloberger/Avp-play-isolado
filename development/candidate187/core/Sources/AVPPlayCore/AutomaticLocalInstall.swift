import Foundation

public struct LocalReplacementConsent: Codable, Sendable, Equatable {
    public let device: String
    public let bundleID: String
    public let version: String?
    public let build: String?
    public let appURL: String?
    public init(device: String, app: InstalledApp) {
        self.device = device; bundleID = app.bundleIdentifier; version = app.version
        build = app.bundleVersion; appURL = app.url
    }
    public static func requireCurrent(apps: [InstalledApp], device: String, bundle: String,
                                      consent: LocalReplacementConsent?) throws {
        let installed = apps.filter { $0.bundleIdentifier == bundle }
        guard installed.count <= 1 else { throw ToolchainError.signingBlocked("Instalação ambígua; confirme novamente.") }
        let current = installed.first.map { LocalReplacementConsent(device: device, app: $0) }
        guard current == consent else {
            throw ToolchainError.signingBlocked("A instalação mudou ou falta confirmação para substituí-la. Volte à biblioteca e confirme novamente.")
        }
    }
}

public struct AutomaticLocalPlan: Sendable {
    public var request: InstallRequest
    public let replacement: LocalReplacementConsent?
    public let profile: URL
    public var steps: [InstallStep] { InstallStep.localAPKInstall }
}

public enum AutomaticLocalInstall {
    public static func launchIdentity(from job: Job, variantID: String) throws -> (device: String, bundle: String) {
        guard job.state == .finished, job.completed.contains(.stage),
              job.request.localAPKVariantID == variantID,
              let device = job.request.device, !device.isEmpty,
              let bundle = job.request.bundleId, SigningRecord.isSafeBundleId(bundle) else {
            throw JobError.cannotResume("Conclua a instalação e a transferência desta variante antes de executar no Vision Pro.")
        }
        return (device, bundle)
    }

    /// Continue an existing native installation without rebuilding, signing or changing its Job.
    public static func stageContinuation(from installed: Job) throws -> Job {
        guard installed.request.localAPKVariantID != nil,
              installed.completed.contains(.build),
              let bundle = installed.request.bundleId, SigningRecord.isSafeBundleId(bundle),
              installed.request.device != nil else {
            throw JobError.cannotResume("É necessário um Job com instalação concluída, variante, dispositivo e Bundle ID explícitos.")
        }
        var request = installed.request
        request.resign = false
        request.restoreSaves = false
        return Job(recipe: installed.recipe, request: request, steps: [.stage],
                   toolchainCommit: installed.toolchainCommit)
    }

    public static func plan(artifact: ReusableBuild, job: Job, recipe: Recipe, device: Device, team: String,
                            apps: [InstalledApp], report: @Sendable (String) -> Void = { _ in }) throws -> AutomaticLocalPlan {
        let identities = SigningWarmUp.existingIdentities(team: team)
        do {
            return try plan(artifact: artifact, job: job, recipe: recipe, device: device, team: team, apps: apps,
                profiles: ExistingAppSigner.profiles(), identities: identities, free: AppleTeams.isFree(team), report: report)
        } catch {
            // Integrity and identity checks precede any Apple provisioning request.
            try RuntimePolicy177.requireArtifact(artifact)
            guard job.request.team == nil || job.request.team == team,
                  let identity = identities.first else { throw error }
            let target = KleptonRecipeCompatibility.resolve(recipe).toolchain.target
            let matches = apps.filter { $0.bundleIdentifier.hasSuffix(".target." + target) }
            guard matches.count <= 1 else { throw error }
            let bundle = matches.first?.bundleIdentifier ?? artifact.bundleID
            try LocalBundleIdentity(destination: bundle, source: artifact.bundleID).validate(target: target)
            var entitlements = try ReusableBuild.infoPlist(artifact.workspace.appendingPathComponent("visionos/Klepton.entitlements"))
            if AppleTeams.isFree(team) {
                entitlements.removeValue(forKey: "com.apple.developer.kernel.extended-virtual-addressing")
                entitlements.removeValue(forKey: "com.apple.developer.low-latency-streaming")
            }
            let request = ProfileProvisioning(bundle: bundle, team: team, device: device.udid, identity: identity,
                entitlements: try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0))
            try request.provisionAutomatically(root: DataLocation.base.appendingPathComponent("profile-setup"), report: report)
            return try plan(artifact: artifact, job: job, recipe: recipe, device: device, team: team, apps: apps,
                profiles: ExistingAppSigner.profiles(), identities: identities, free: AppleTeams.isFree(team), report: report)
        }
    }

    static func plan(artifact: ReusableBuild, job: Job, recipe: Recipe, device: Device, team: String,
                     apps: [InstalledApp], profiles: [ExistingAppSigner.Profile], identities: [String], free: Bool,
                     report: @Sendable (String) -> Void = { _ in }) throws -> AutomaticLocalPlan {
        if let originalTeam = job.request.team, originalTeam != team {
            throw ToolchainError.signingBlocked("A compilação preservada está associada à Team \(originalTeam). Selecione essa Team e recupere sua identidade de assinatura; a Team \(team) não será usada automaticamente.")
        }
        let target = KleptonRecipeCompatibility.resolve(recipe).toolchain.target
        let matches = apps.filter { $0.bundleIdentifier.hasSuffix(".target." + target) }
        guard matches.count <= 1 else { throw ToolchainError.signingBlocked("Mais de uma instalação deste jogo; identificação automática ambígua.") }
        let requested = try ReusableBuild.infoPlist(artifact.workspace.appendingPathComponent("visionos/Klepton.entitlements"))
        let known = [artifact.bundleID, Toolchain.defaultBundleId(target: target)]
        guard !identities.isEmpty else {
            throw ToolchainError.signingBlocked(L(
                "No valid Apple Development identity for Team \(team) is available in the Keychain. Check Xcode > Settings > Accounts > Manage Certificates; the preserved build was not changed.",
                "Nenhuma identidade Apple Development válida da equipe \(team) foi reconhecida no Keychain. Confira Xcode > Ajustes > Contas > Gerenciar Certificados; a compilação preservada não foi alterada."))
        }
        let profileBundles = profiles.compactMap { profile -> String? in
            guard let ent = profile.values["Entitlements"] as? [String: Any],
                  let appID = ent["application-identifier"] as? String,
                  let dot = appID.firstIndex(of: ".") else { return nil }
            let bundle = String(appID[appID.index(after: dot)...])
            return SigningRecord.isSafeBundleId(bundle) && bundle.hasSuffix(".target." + target) ? bundle : nil
        }
        let candidates = matches.first.map { [$0.bundleIdentifier] } ?? Array(Set(known + profileBundles)).sorted {
            (known.firstIndex(of: $0) ?? Int.max, $0) < (known.firstIndex(of: $1) ?? Int.max, $1)
        }
        var chosen: (String, ExistingAppSigner.Plan)?
        var compatibleFallbacks: [(String, ExistingAppSigner.Plan)] = []
        for bundle in candidates {
            try LocalBundleIdentity(destination: bundle, source: artifact.bundleID).validate(target: target)
            if let result = try? ExistingAppSigner.select(profiles: profiles, identities: identities,
                team: team, bundle: bundle, device: device.udid, requested: requested, free: free) {
                if !matches.isEmpty || known.contains(bundle) { chosen = (bundle, result.plan); break }
                compatibleFallbacks.append((bundle, result.plan))
            }
        }
        if chosen == nil, compatibleFallbacks.count == 1 { chosen = compatibleFallbacks[0] }
        if chosen == nil, compatibleFallbacks.count > 1 { throw ToolchainError.signingBlocked("Perfis de mais de uma identidade compatível; seleção automática ambígua.") }
        guard let (bundle, profile) = chosen else {
            throw ToolchainError.signingBlocked(L(
                "No existing development provisioning profile matches Bundle ID \(known[0]), Team \(team), the connected Vision Pro, the selected Apple Development certificate, and the required entitlements. In Xcode, open Signing & Capabilities for target \(target), select this Team and Bundle ID, and use Automatically manage signing to obtain its profile. Keep the existing certificate; no game rebuild is needed.",
                "Falta um perfil de desenvolvimento compatível com o Bundle ID \(known[0]), Team \(team), Vision Pro conectado, certificado Apple Development e permissões necessárias. No Xcode, abra Signing & Capabilities do target \(target), selecione esta equipe e Bundle ID e use Automaticamente gerenciar assinatura para obter o perfil. Mantenha o certificado existente; não é necessário recompilar o jogo."))
        }
        var request = job.request // Keep the native build options, not mutable global preferences.
        request.reuseBuildOnly = true; request.automaticLocalInstall = true
        request.device = device.udid; request.team = team; request.live = true
        request.requireExistingBuildOnResume = true
        request.replacementConsent = nil
        request.resign = matches.isEmpty ? nil : true
        request.restoreSaves = false // Existing saves are never restored/overwritten by this flow.
        try LocalBundleIdentity(destination: bundle, source: artifact.bundleID).apply(to: &request, target: target)
        report("Reutilizando \(artifact.files.count) arquivos; identidade \(bundle); perfil \(profile.profile.lastPathComponent).")
        return AutomaticLocalPlan(request: request, replacement: matches.first.map { LocalReplacementConsent(device: device.udid, app: $0) }, profile: profile.profile)
    }
}
