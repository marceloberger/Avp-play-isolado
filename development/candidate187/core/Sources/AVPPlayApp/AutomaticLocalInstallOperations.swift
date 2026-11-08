import AppKit
import AVPPlayCore
import Foundation

private enum AutomaticLocalAdmission: Sendable {
    case reuse(AutomaticLocalPlan)
    case fresh(Device, InstalledApp?)
}

extension AppModel {
    func launchLocalAPK(_ recipe: Recipe, variantID: String) {
        guard !isBusy(recipe.id), !localAutomaticPlanning.contains(recipe.id) else { return }
        do {
            guard let job = jobs.filter({ $0.recipe.id == recipe.id && $0.request.localAPKVariantID == variantID && $0.state == .finished && $0.completed.contains(.stage) })
                .max(by: { $0.updated < $1.updated })
                else { throw JobError.cannotResume("Conclua a instalação e a transferência desta variante antes de executar no Vision Pro.") }
            let identity = try AutomaticLocalInstall.launchIdentity(from: job, variantID: variantID)
            guard device?.udid == identity.device else { throw JobError.cannotResume("Selecione o Vision Pro usado nesta instalação antes de executar.") }
            localAutomaticPlanning.insert(recipe.id)
            Task {
                defer { localAutomaticPlanning.remove(recipe.id) }
                do {
                    try await Task.detached {
                        _ = try RuntimePolicy177.source(at: URL(fileURLWithPath: job.request.toolchain))
                        let control = DeviceControl(), connected = try control.pick(udid: identity.device)
                        let apps = try control.apps(device: connected)
                        guard let installed = apps.first(where: { $0.bundleIdentifier == identity.bundle }),
                              let stamp = installed.bundleVersion.flatMap(AppStamp.parse),
                              stamp.versionCode == recipe.versionCode, stamp.toolchain == 850, stamp.modified else {
                            throw JobError.cannotResume("O aplicativo instalado diverge do Job concluído. Confira a instalação antes de executar.")
                        }
                        try control.launch(bundle: identity.bundle, device: connected)
                    }.value
                    localOperationMessages[recipe.id] = "Execução solicitada e confirmada pelo Vision Pro."
                } catch { localOperationMessages[recipe.id] = "Não foi possível executar: \(error)" }
            }
        } catch { localOperationMessages[recipe.id] = "Execução bloqueada: \(error)" }
    }

    func transferLocalAPKFiles(_ recipe: Recipe, variantID: String) {
        guard !isBusy(recipe.id) else { return }
        let matching = jobs.filter { $0.recipe.id == recipe.id && $0.request.localAPKVariantID == variantID }
        if let pending = matching.first(where: {
            $0.remaining.contains(.stage) && !$0.remaining.contains(.build)
                && ($0.state == .failed || $0.state == .waiting)
        }) {
            resume(pending)
            return
        }
        do {
            guard let installed = matching.filter({ $0.completed.contains(.build) })
                .max(by: { $0.updated < $1.updated }) else {
                throw JobError.cannotResume("Nenhuma instalação concluída foi registrada pelo AVP Play para esta variante. Uma instalação manual pelo Xcode não cria esse registro. Use “Build, sign and install” para reutilizar um build verificado, ou “Nova instalação do zero”; após a instalação confirmada, a transferência continuará no mesmo Job.")
            }
            let continuation = try AutomaticLocalInstall.stageContinuation(from: installed)
            let job = try paths.jobs.admitLocal182(continuation).job
            if !queued.contains(job.id) && runningJob != job.id { queued.append(job.id) }; selectedJob = job.id
            reloadJobs(); localLibraryRevision += 1; pump()
        } catch { localOperationMessages[recipe.id] = "Transferência bloqueada: \(error)" }
    }

    func startAutomaticLocalInstall(_ game: Game, variantID: String, fresh: Bool = false) {
        guard !localAutomaticPlanning.contains(game.id), !isBusy(game.id), localOperationWorkers[game.id] == nil,
              let selectedDevice = device, let tc = toolchain(for: game) else { return }
        localAutomaticPlanning.insert(game.id)
        localOperationMessages[game.id] = "Conferindo compilação preservada e identidade Apple…"
        let registry = localVariantStore, store = paths.jobs, workspace = localWorkspaceRoot, team = teamId
        let selectedOptions = options(for: game)
        let resolvedRuntime = runtimeBuildPreferences.resolve(overrides: RuntimeBuildOverrides(
            surrealSupport: selectedOptions.surrealSupport, controllerMode: selectedOptions.controllerMode,
            frameGeneration: selectedOptions.frameGeneration, surrealSDK: selectedOptions.surrealSDK))
        var requestedRuntime = InstallRequest(toolchain: tc.root.path)
        requestedRuntime.coreMods = selectedOptions.coreMods == true
        requestedRuntime.controllerMode = resolvedRuntime.controllerMode
        requestedRuntime.frameGeneration = resolvedRuntime.frameGeneration
        requestedRuntime.surrealSupport = resolvedRuntime.surrealSupport
        requestedRuntime.surrealSDK = resolvedRuntime.surrealSDK
        requestedRuntime.xrPrediction = selectedOptions.xrPrediction == true
        requestedRuntime.experimental = experimentalImplementations
        requestedRuntime.metalFX = metalFXUpscaling
        if metalFXUpscaling { requestedRuntime.resolution = metalFXResolution }
        Task {
            defer { localAutomaticPlanning.remove(game.id) }
            do {
                let plan: AutomaticLocalAdmission = try await Task.detached(priority: .userInitiated) { [weak self] in
                    let report: @Sendable (String) -> Void = { text in
                        Task { @MainActor [weak self] in self?.localOperationMessages[game.id] = text }
                    }
                    guard let variant = registry.variants(for: game.recipe).first(where: { $0.id == variantID }) else {
                        throw LocalAPKVariantError.invalidRecord("Variante local ausente.")
                    }
                    if game.recipe.localExperimental != nil {
                        let selected = try registry.validatedForPreparation(id: variantID, for: game.recipe)
                        try LocalExperimentalAdmission.requireValidated(recipe: game.recipe, selected: selected)
                    }
                    var compatibility = requestedRuntime
                    compatibility.localAssetsSHA256 = try LocalAPKBuildEvidence.assetsHash(variant)
                    let recovery = LocalBuildRecovery(workspaceRoot: workspace)
                    let historicalInstallations = try LocalAPKLearningStore(variants: registry).load(game.recipe).installations
                    let recovered: (ReusableBuild, Job)?
                    if fresh { recovered = nil }
                    else if game.recipe.localExperimental != nil {
                        recovered = try LocalExperimentalAdmission.existingBuild(jobs: store,
                            workspaceRoot: workspace, recipe: game.recipe, variant: variant,
                            toolchain: tc, requested: compatibility, report: report)
                    } else {
                        recovered = try recovery.artifact(jobs: store, recipe: game.recipe,
                            variant: variant, toolchain: tc, legacyInstallations: historicalInstallations,
                            variantStore: registry, requestedRuntime: compatibility, report: report)
                    }
                    let control = DeviceControl(), device = try control.pick(udid: selectedDevice.udid)
                    let apps = try control.apps(device: device)
                    if let (artifact, job) = recovered {
                        return .reuse(try AutomaticLocalInstall.plan(artifact: artifact, job: job, recipe: game.recipe,
                            device: device, team: team, apps: apps, report: report))
                    }
                    let target = KleptonRecipeCompatibility.resolve(game.recipe).toolchain.target
                    let matches = apps.filter { $0.bundleIdentifier.hasSuffix(".target." + target) }
                    guard matches.count <= 1 else {
                        throw ToolchainError.signingBlocked("Mais de uma instalação deste jogo; identificação automática ambígua.")
                    }
                    return .fresh(device, matches.first)
                }.value
                switch plan {
                case .reuse(var approved):
                    let requested = options(for: game)
                    let before = approved.request
                    guard (requested.coreMods == nil || requested.coreMods == (before.coreMods ?? false)),
                          (requested.frameGeneration == nil || requested.frameGeneration == (before.frameGeneration ?? .off)),
                          (requested.surrealSDK == nil || requested.surrealSDK == (before.surrealSDK ?? .verified)),
                          (surrealSupport || before.surrealSupport == false) else {
                        throw JobError.cannotResume("O build preservado usa outras opções de runtime. Execute um novo Build only explícito para aplicar a escolha; o app existente não será recompilado automaticamente.")
                    }
                    if let existing = approved.replacement {
                        guard confirmLocalReplacement(game: game, consent: existing) else { return }
                        approved.request.replacementConsent = existing
                    }
                    try enqueueAutomaticLocalPlan(approved, recipe: game.recipe)
                    localOperationMessages[game.id] = "Compilação reutilizada; acompanhe assinatura e instalação abaixo."
                case .fresh(let device, let installed):
                    let consent = installed.map { LocalReplacementConsent(device: device.udid, app: $0) }
                    if let consent, !confirmLocalReplacement(game: game, consent: consent) { return }
                    enqueue(game, steps: InstallStep.localAPKInstall,
                        show: true, localAPKVariantID: variantID, automaticLocalInstall: true, freshLocalBuild: fresh,
                        replacementConsent: consent, automaticBundleID: installed?.bundleIdentifier,
                        automaticDeviceID: device.udid)
                    localOperationMessages[game.id] = "Preparação, build, assinatura e instalação enfileirados; acompanhe o progresso abaixo."
                }
            } catch {
                localOperationMessages[game.id] = "Operação bloqueada: \(error)"
                localOperationDiagnostics[game.id] = "\(error)"
                reloadJobs()
            }
        }
    }

    private func confirmLocalReplacement(game: Game, consent: LocalReplacementConsent) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Atualizar \(game.recipe.title)?"
        alert.informativeText = "Identidade preservada: \(consent.bundleID)\nSomente o aplicativo será assinado e substituído. Os arquivos selecionados serão conferidos e os ausentes ou divergentes serão transferidos após a instalação. Saves não serão restaurados. Nenhum app será removido.\nO perfil e o certificado locais foram validados; a assinatura efetiva do app instalado não é exposta pelo Vision Pro, portanto a continuidade de assinatura e Keychain não pode ser garantida por essa consulta."
        alert.addButton(withTitle: "Cancelar")
        alert.addButton(withTitle: "Confirmar atualização")
        guard alert.runModal() == .alertSecondButtonReturn else {
            localOperationMessages[game.id] = "Atualização cancelada; nenhum aplicativo foi alterado."
            reloadJobs()
            return false
        }
        return true
    }

    func enqueueAutomaticLocalPlan(_ plan: AutomaticLocalPlan, recipe: Recipe) throws {
        guard !isBusy(recipe.id) else { throw JobError.cannotResume("Já existe um trabalho para este jogo.") }
        if let existing = plan.replacement, plan.request.replacementConsent != existing {
            throw JobError.cannotResume("Falta confirmar a substituição do aplicativo.")
        }
        let job = try paths.jobs.admitLocal182(Job(recipe: recipe, request: plan.request, steps: plan.steps,
            toolchainCommit: Toolchain(root: URL(fileURLWithPath: plan.request.toolchain)).commit())).job
        if !queued.contains(job.id) && runningJob != job.id { queued.append(job.id) }; reloadJobs(); localLibraryRevision += 1; pump()
    }

    func preserveCompletedLocalBuild(_ job: Job) async {
        let registry = localVariantStore, jobs = paths.jobs, workspace = localWorkspaceRoot
            do {
                try await Task.detached {
                    guard let variant = registry.variants(for: job.recipe).first(where: { $0.id == job.request.localAPKVariantID }) else { return }
                    if job.recipe.localExperimental != nil {
                        _ = try LocalExperimentalAdmission.existingBuild(jobs: jobs, workspaceRoot: workspace,
                            recipe: job.recipe, variant: variant,
                            toolchain: Toolchain(root: URL(fileURLWithPath: job.request.toolchain)),
                            requested: job.request)
                        return
                    }
                    let historicalInstallations = try LocalAPKLearningStore(variants: registry).load(job.recipe).installations
                    _ = try LocalBuildRecovery(workspaceRoot: workspace).artifact(jobs: jobs, recipe: job.recipe,
                        variant: variant, toolchain: Toolchain(root: URL(fileURLWithPath: job.request.toolchain)),
                        legacyInstallations: historicalInstallations, variantStore: registry)
                }.value
            } catch { localOperationDiagnostics[job.recipe.id] = "Não foi possível guardar evidência redundante da compilação: \(error)" }
    }
}
