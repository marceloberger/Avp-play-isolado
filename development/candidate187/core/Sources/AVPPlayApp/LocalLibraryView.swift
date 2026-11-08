import AppKit
import AVPPlayCore
import SwiftUI

struct LocalLibraryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var advanced = false
    @State private var experimentalRuntime: ExperimentalRuntime183 = .klepton850
    @State private var runtimeAvailable = false
    @State private var runtimeAvailability = "Verificando disponibilidade e integridade…"
    @State private var appIDEdits: [String: String] = [:]
    @State private var sourceEdits: [String: String] = [:]
    @State private var selectedVariants: [String: String] = [:]
    @State private var externalDestinations: [String: String] = [:]
    @State private var externalEvidence: [String: String] = [:]
    @State private var externalKinds: [String: String] = [:]
    private var recipe: Recipe? { model.localRecipes.first { $0.id == model.selectedLocalRecipeID } }
    private var provisional: LocalProvisionalRecipe? { model.localProvisionalRecipes.first { $0.id == model.selectedLocalRecipeID } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Local Library").font(.largeTitle.bold())
                Button("Importar APK ou pasta do jogo", systemImage: "doc.badge.plus") {
                    model.autoImportLocalAPK()
                }.buttonStyle(.borderedProminent)
                    .disabled(model.localImport.isRunning)
                Button("Importação genérica experimental", systemImage: "shippingbox.and.arrow.down") {
                    model.importGenericExperimentalAPK()
                }.buttonStyle(.bordered)
                    .disabled(model.localImport.isRunning)
                importStatus
                if let message = model.localCommunitySelectionMessage {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(message).font(.callout).foregroundStyle(.orange)
                        ForEach(model.localCommunitySelectionChoices) { choice in
                            Button("Abrir \(choice.title) · \(choice.version) · SHA-256 \(String(choice.sha256.prefix(12)))…") {
                                model.selectLocalCommunityVariant(choice)
                            }
                        }
                    }.padding(10).background(Color.orange.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 8))
                }
                if let recipe {
                    gameCard(recipe)
                    RuntimeGameSettings(recipe: recipe)
                }
                if let provisional { provisionalCard(provisional) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190))], spacing: 14) {
                    ForEach(model.localLibraryGames.filter { $0.package != recipe?.package && $0.id != recipe?.id }, id: \.id) { item in
                        Button { model.selectLocalLibraryItem(item.id, isProvisional: false) } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                LocalLibraryCover(recipe: item).frame(height: 108)
                                Text(item.title).font(.headline).lineLimit(2)
                                Text(gameSituation(item)).font(.caption).foregroundStyle(.secondary)
                            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(model.selectedLocalRecipeID == item.id ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }.buttonStyle(.plain)
                    }
                    ForEach(model.localProvisionalRecipes.filter { $0.id != provisional?.id }, id: \.id) { item in
                        Button { model.selectLocalLibraryItem(item.id, isProvisional: true) } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                Image(systemName: "shippingbox").font(.largeTitle).frame(maxWidth: .infinity).frame(height: 108)
                                Text(item.title).font(.headline).lineLimit(2)
                                Text("Receita local provisória · ainda não testado").font(.caption).foregroundStyle(.secondary)
                            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(model.selectedLocalRecipeID == item.id ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }.buttonStyle(.plain)
                    }
                }
                DisclosureGroup("Configurações avançadas", isExpanded: $advanced) {
                    advancedSettings.padding(.top, 12)
                }
            }.padding(24).frame(maxWidth: 1050, alignment: .leading).frame(maxWidth: .infinity)
        }.navigationTitle("Local Library")
            .task { model.loadLocalRecipes() }
            .onChange(of: model.localImport.variantID) { _, id in
                if let recipeID = model.localImport.recipeID { selectedVariants[recipeID] = id }
            }
            .sheet(item: $model.localAdditionalReview) { review in
                LocalAdditionalFilesReviewSheet(review: review) { destinations in
                    try model.confirmOptionalLocalFiles(review, destinations: destinations)
                }
            }
    }

    @ViewBuilder private var importStatus: some View {
        let state = model.localImport
        if state.isRunning {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(state.cancelRequested ? "Cancelamento solicitado..." : "Importando...").font(.headline)
                    Spacer()
                    Button("Cancelar") { model.cancelLocalImport() }.disabled(state.cancelRequested)
                }
                if let progress = state.progress, progress.total > 0 {
                    ProgressView(value: Double(progress.done), total: Double(progress.total))
                    Text("\(progress.phase) · \(ByteCountFormatter.string(fromByteCount: progress.done, countStyle: .file)) de \(ByteCountFormatter.string(fromByteCount: progress.total, countStyle: .file))")
                        .font(.caption).foregroundStyle(.secondary)
                } else { ProgressView(state.progress?.phase ?? "Identificando jogo").controlSize(.small) }
            }
        } else if let message = state.message {
            VStack(alignment: .leading, spacing: 5) {
                Text(message).font(.headline)
                if let folder = state.folderPath { Text("Pasta: \(folder)").textSelection(.enabled) }
                if let apk = state.apkPath { Text("Arquivo: \(apk)").textSelection(.enabled) }
                if !state.missingRequired.isEmpty {
                    Text("Requisitos pendentes: \(state.missingRequired.joined(separator: ", "))")
                    Button("Adicionar OBBs / assets e verificar novamente") { model.addAutomaticImportAssets() }
                        .buttonStyle(.borderedProminent)
                }
                if state.variantID != nil, let recipe = model.localRecipes.first(where: { $0.id == state.recipeID }) {
                    let imported = model.localVariantStore.variants(for: recipe).first { $0.id == state.variantID }
                    let assets = imported?.assets ?? []
                    let missing = Set(imported?.missingRequiredFiles ?? state.missingRequired)
                    let requiredFound = max(0, recipe.files.filter(\.required).count - missing.count)
                    let optionalCount = recipe.files.filter { file in !file.required && assets.contains { $0.name == file.name } }.count
                    let extras = assets.filter { $0.isAdditional == true }
                    let automaticCount = extras.filter { $0.automaticallyIncluded == true }.count
                    Text("Resumo: \(requiredFound) obrigatórios encontrados · \(optionalCount) opcionais incluídos · \(extras.count) adicionais incluídos (\(automaticCount) automaticamente) · \(state.unmatchedFiles.count) pendentes de revisão · \(state.ignoredFileCount) ignorados")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(state.unmatchedFiles, id: \.self) { path in
                        let url = URL(fileURLWithPath: path)
                        HStack {
                            Text("\(url.lastPathComponent) · \(LocalGameImport.classification(url))")
                            Spacer(); Text(path).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    if !state.unmatchedFiles.isEmpty {
                        Button(model.localAdditionalReviewPreparing ? "Calculando hashes dos arquivos…" : "Revisar e incluir arquivos adicionais…") {
                            model.includeOptionalLocalFiles()
                        }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("review-additional-files")
                            .disabled(state.isRunning || model.localAdditionalReviewPreparing)
                    }
                    if let error = model.localAdditionalReviewError {
                        Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
                if state.canCreateProvisional {
                    Button("Criar receita local provisória") { model.offerCreateProvisionalAPK() }
                        .buttonStyle(.borderedProminent)
                }
            }.font(.callout)
        }
    }

    @ViewBuilder private func provisionalCard(_ record: LocalProvisionalRecipe) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text(record.title).font(.title2.bold())
                Label(record.experimentalReviewState185, systemImage: "doc.badge.questionmark").foregroundStyle(.orange)
                Text("Ainda não testado").foregroundStyle(.secondary)
                if let target = record.communityTarget {
                    Label("\(target.title) · Community candidate", systemImage: "person.3")
                    Text("Target Klepton candidato: \(target.target)")
                    Text("Versão catalogada: \(target.versionName) (\(target.versionCode)); versão observada no APK: \(record.versionName ?? "ausente") (\(record.versionCode ?? "ausente"))")
                        .font(.caption)
                    Text("Proveniência: catálogo comunitário + package/version correspondentes aos metadados inspecionados do APK.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Requisitos genéricos observados: APK com SHA-256; package/version; arm64-v8a; libUE4.so. O Klepton deriva entrypoint, bibliotecas e caminho de OBB do APK extraído.")
                        .font(.caption)
                    if record.genericTargetCanPrepareAndBuild {
                        Label("Target identificado; requisitos genéricos de Prepare e Build only comprovados", systemImage: "checkmark.circle")
                            .foregroundStyle(.green)
                    }
                }
                Text("Package ID: \(record.package)")
                Text("Variante: \(record.versionName ?? "version name ausente") · Version code \(record.versionCode ?? "ausente") · SHA-256 \(String(record.apkSHA256.prefix(16)))…")
                    .font(.caption).textSelection(.enabled)
                Text("APK: \(record.apkPath)").font(.caption).textSelection(.enabled)
                Text("Arquiteturas: \(record.architectures.isEmpty ? "não detectadas" : record.architectures.joined(separator: ", "))")
                Text("Bibliotecas nativas: \(record.nativeLibraries.isEmpty ? "nenhuma no APK" : record.nativeLibraries.joined(separator: ", "))")
                Text("Assets internos: \(record.assets.count)")
                ProvisionalPrognosisView170(record: record)
                ForEach(record.analysis169.decisions, id: \.field) { decision in
                    Text("\(decision.field): \(decision.value ?? "desconhecido") · \(decision.evidence) · \(decision.source)").font(.caption)
                }
                ForEach(record.analysis169.diagnostics) { diagnostic in
                    Text("\(diagnostic.severity.rawValue) · \(diagnostic.message) · \(diagnostic.remedy)").font(.caption)
                }
                if let catalog = LocalSupportCatalog.load() {
                    ForEach(catalog.diagnostics(package: record.package, versionCode: record.versionCode), id: \.self) { message in
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !record.externalFileReferences.isEmpty {
                    Text("Referências externas observadas no manifesto (não resolvidas):")
                    ForEach(record.externalFileReferences, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                }
                Button("Associar OBB ou arquivos adicionais") { model.associateProvisionalExternalFiles(record) }
                if record.externalFiles.isEmpty { Text("Nenhum arquivo externo associado.").font(.caption).foregroundStyle(.secondary) }
                ForEach(record.externalFiles) { file in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(URL(fileURLWithPath: file.path).lastPathComponent) · \(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)) · \(file.sha256.map { "SHA-256 \(String($0.prefix(16)))…" } ?? "integridade ainda não verificada")")
                            .font(.caption).textSelection(.enabled)
                        if record.experimentalTarget != nil {
                            HStack {
                                Picker("Tipo", selection: Binding(
                                    get: { externalKinds[file.path] ?? file.kind ?? (file.fileName.lowercased().hasSuffix(".obb") ? "obb" : "asset") },
                                    set: { externalKinds[file.path] = $0 })) {
                                    Text("OBB").tag("obb")
                                    Text("Asset").tag("asset")
                                    Text("Outro").tag("other")
                                }.frame(width: 150)
                                TextField("Pasta de destino (android-files/...)", text: Binding(
                                    get: { externalDestinations[file.path] ?? file.destination ?? "" },
                                    set: { externalDestinations[file.path] = $0 }))
                            }
                            TextField("Evidência do destino", text: Binding(
                                get: { externalEvidence[file.path] ?? file.mappingEvidence ?? "" },
                                set: { externalEvidence[file.path] = $0 }))
                            Button("Validar hash e salvar associação") {
                                model.mapProvisionalExternalFile(record, path: file.path,
                                    kind: externalKinds[file.path] ?? file.kind ?? "asset",
                                    destination: externalDestinations[file.path] ?? file.destination ?? "",
                                    evidence: externalEvidence[file.path] ?? file.mappingEvidence ?? "")
                            }.disabled((externalDestinations[file.path] ?? file.destination ?? "").isEmpty
                                || (externalEvidence[file.path] ?? file.mappingEvidence ?? "").isEmpty)
                        }
                    }
                }
                if !record.externalFileReferences.isEmpty || !record.externalFiles.isEmpty {
                    Text("A associação registra origem, destino declarado, tamanho e hash. Ela não comprova completude nem opcionalidade; referências explícitas do APK sem correspondência mantêm a receita bloqueada. Build only não testa o conteúdo em execução.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !record.compatibilityBlockers.isEmpty {
                    Text("Pendências de compatibilidade:").font(.headline)
                    ForEach(record.compatibilityBlockers, id: \.self) { Text("• \($0)").font(.caption).foregroundStyle(.orange) }
                }
                    Picker("Toolchain experimental", selection: $experimentalRuntime) {
                        ForEach(ExperimentalRuntime183.permitted, id: \.self) { profile in
                            Text(profile.label).tag(profile)
                        }
                    }
                    Text("O rascunho pode ser salvo com pendências. Integridade será exigida para registrar o APK e antes de Prepare/Build.").font(.caption)
                Text(runtimeAvailability).font(.caption).foregroundStyle(runtimeAvailable ? Color.secondary : Color.orange)
                let appID = Binding<String>(
                    get: { appIDEdits[record.id] ?? record.experimentalDraft185?.appID ?? record.experimentalTarget?.appID ?? record.automaticIdentity?.appID ?? "" },
                    set: { appIDEdits[record.id] = $0 })
                let provenance = Binding<String>(
                    get: { sourceEdits[record.id] ?? record.experimentalDraft185?.provenance ?? record.experimentalTarget?.provenance ?? record.automaticIdentity?.source ?? "" },
                    set: { sourceEdits[record.id] = $0 })
                ExperimentalIdentityEditor185(appID: appID, provenance: provenance) {
                    model.saveExperimentalDraft(record, appID: appID.wrappedValue,
                        provenance: provenance.wrappedValue, runtime: experimentalRuntime)
                }
                ForEach(record.automaticTargetBlockers, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                Text("Salvar dados declarados não confirma identidade, compatibilidade ou integridade. Campos desconhecidos permanecem pendentes.").font(.caption)
                if record.genericTargetCanPrepareAndBuild {
                    Button("Verificar integridade e habilitar Prepare / Build only") {
                        model.activateCommunityTarget(record)
                    }.buttonStyle(.borderedProminent)
                }
                if record.experimentalTarget != nil {
                    Text("Target experimental: \(record.experimentalTarget?.target ?? "") · \(record.experimentalTarget?.toolchain ?? "desconhecido") · não verificado")
                        .font(.caption).foregroundStyle(.orange)
                    if record.experimentalRecipe != nil {
                        Button("Revisar e registrar com \(experimentalRuntime.label)") {
                            model.activateExperimentalTarget(record,
                                appID: record.experimentalTarget?.appID ?? "",
                                provenance: record.experimentalTarget?.provenance ?? "", runtime: experimentalRuntime)
                        }.buttonStyle(.borderedProminent)
                    }
                }
                HStack {
                    Button("Prepare") {}.disabled(true)
                    Button("Build only") {}.disabled(true)
                    Button("Build, sign and install") {}.disabled(true)
                }
                Text(record.genericTargetCanPrepareAndBuild
                     ? "Após verificar novamente o APK e registrá-lo na biblioteca local, Prepare e Build only ficam disponíveis no cartão normal. A instalação continua sujeita às verificações de assinatura e dispositivo."
                     : "Nenhuma ação de processamento é liberada enquanto a identidade do target genérico e suas bibliotecas de entrada não forem comprovadas.")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
                .task(id: record.id + experimentalRuntime.rawValue) {
                    runtimeAvailable = false
                    runtimeAvailability = "Verificando disponibilidade e integridade…"
                    let profile = experimentalRuntime, analysis = record.genericAnalysis
                    let failure = await Task.detached(priority: .utility) { () -> String? in
                        do { _ = try profile.verifiedSource(analysis: analysis); return nil }
                        catch { return String(describing: error) }
                    }.value
                    guard !Task.isCancelled else { return }
                    runtimeAvailable = failure == nil
                    runtimeAvailability = failure ?? "Disponível e íntegro: " + profile.label
                }
        }
    }

    private func variant(_ recipe: Recipe) -> LocalAPKVariant? {
        let variants = model.localAPKVariants(for: recipe)
        let chosen = selectedVariants[recipe.id]
            ?? (model.localImport.recipeID == recipe.id ? model.localImport.variantID : nil)
        if let chosen, let selected = variants.first(where: { $0.id == chosen }) { return selected }
        if let hash = model.localLearning(recipe)?.current?.preferredHash,
           let recognized = variants.first(where: { $0.sha256 == hash }) { return recognized }
        return variants.sorted { $0.registeredAt > $1.registeredAt }.first
    }

    private func gameSituation(_ recipe: Recipe) -> String {
        if model.importingLocalGameIDs.contains(recipe.id) { return "Importando..." }
        if let job = model.localCardJob(recipe), job.id == model.runningJob || model.queued.contains(job.id) { return jobTitle(job) }
        if model.localOperationWorkers[recipe.id] != nil { return model.localOperationMessages[recipe.id] ?? "Em andamento" }
        if let variant = variant(recipe), let status = model.localConfirmationPresentation(variant, recipe: recipe) { return status }
        return model.localAPKVariants(for: recipe).isEmpty ? "Aguardando importação" : "APK importado · ainda não testado"
    }

    @ViewBuilder private func gameCard(_ recipe: Recipe) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                if let variant = variant(recipe) { LocalPrognosisView170(recipe: recipe, variant: variant) }
                HStack(alignment: .top) {
                    LocalLibraryCover(recipe: recipe).frame(width: 165, height: 95).clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(recipe.title).font(.title2.bold())
                        Text(recipe.localExperimental != nil ? "Receita experimental" :
                            (recipe.files.contains { $0.id == "local-community" } ? "Receita comunitária" :
                             (recipe.status.playability == "verified" ? "Receita verificada" : "Receita comunitária · não validada em execução")))
                            .font(.caption).foregroundStyle(recipe.status.playability == "verified" ? Color.secondary : Color.orange)
                        Text(gameSituation(recipe)).foregroundStyle(.secondary)
                        if recipe.localExperimental == nil,
                           let community = model.localProvisionalRecipes.first(where: { $0.communityRecipe?.id == recipe.id }) {
                            Label("Community candidate · target \(community.communityTarget?.target ?? recipe.toolchain.target)", systemImage: "person.3")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("Configuração local provisória; APK \(community.versionName ?? "versão ausente") (\(community.versionCode ?? "código ausente")); conteúdo externo ainda precisa ser avaliado para execução.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if recipe.localExperimental != nil {
                            Label("Target genérico experimental · \(recipe.localExperimental?.toolchain ?? "desconhecido") · não verificado", systemImage: "flask")
                                .font(.caption).foregroundStyle(.orange)
                            Text("Meta AppID com procedência registrada; origem: \(recipe.localExperimental?.appIDProvenance ?? "ausente")")
                                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
                if let variant = variant(recipe) {
                    if model.localImport.recipeID != recipe.id,
                       let apk = variant.originalAPKSourcePath { Text("Arquivo: \(apk)").font(.callout).textSelection(.enabled) }
                    if recipe.files.contains(where: { file in
                        file.required && file.role != "apk" && !(variant.assets ?? []).contains(where: { $0.name == file.name })
                    }) {
                        Text("Arquivos necessários para nova instalação não associados")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    let unavailable = model.localImport.isRunning || model.isBusy(recipe.id) || model.localOperationWorkers[recipe.id] != nil || model.localAutomaticPlanning.contains(recipe.id)
                    let compatible = variant.versionMatchesRecipe == true && variant.androidSignature?.verified == true
                        && (variant.missingRequiredFiles ?? []).isEmpty
                        && (try? LocalAPKVariantStore.requireCompatibleDependencies(variant, recipe: recipe)) != nil
                    let installProblem: String? = {
                        do { try LocalExperimentalAdmission.requireEligible(recipe: recipe, variant: variant); return nil }
                        catch { return String(describing: error) }
                    }()
                    let installEligible = installProblem == nil
                    let buildGame = model.localGame(for: recipe)
                    let effectiveToolchain = model.toolchain(for: buildGame)
                    let canInstall = LocalInstallReadiness.canStart(recipe: recipe, variant: variant,
                        runtimeAvailable: effectiveToolchain != nil, xcodeAvailable: model.xcodeProblem == nil,
                        teamValid: model.teamValid, deviceAvailable: model.device != nil)
                    let buildOptions = model.options(for: buildGame)
                    let effectiveRuntime = model.runtimeBuildPreferences.resolve(overrides: RuntimeBuildOverrides(
                        surrealSupport: buildOptions.surrealSupport, controllerMode: buildOptions.controllerMode,
                        frameGeneration: buildOptions.frameGeneration, surrealSDK: buildOptions.surrealSDK))
                    Text(effectiveToolchain.map { "Toolchain efetiva: Klepton \($0.version()) (\($0.commit()))\($0.version() == 850 && $0.commit() == "cc2856c" ? " + TLS168 verificado" : "")" }
                         ?? "Toolchain efetiva indisponível; escolha uma versão válida antes de compilar.")
                        .font(.caption).foregroundStyle(effectiveToolchain == nil ? .orange : .secondary)
                    Text("Runtime efetivo: controles \(effectiveRuntime.controllerMode.rawValue), Frame Generation \(effectiveRuntime.frameGeneration.rawValue), Core Mods \(buildOptions.coreMods == true ? "on" : "off"), Surreal \(effectiveRuntime.surrealSupport ? "on" : "off"), SDK \(effectiveRuntime.surrealSDK.rawValue)")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Prepare") {
                            if model.authorizeForLocalAction(variant, recipe: recipe) { model.prepareLocalAPKVariant(recipe, id: variant.id) }
                        }
                        Button("Build only") {
                            if model.authorizeForLocalAction(variant, recipe: recipe) { model.buildLocalAPKVariant(model.localGame(for: recipe), id: variant.id) }
                        }
                        Button("Build, sign and install") {
                            if model.authorizeForLocalAction(variant, recipe: recipe) { model.installLocalAPKVariant(model.localGame(for: recipe), id: variant.id) }
                        }.buttonStyle(.borderedProminent).disabled(!canInstall)
                        Button("Nova instalação do zero") {
                            if model.authorizeForLocalAction(variant, recipe: recipe) {
                                model.startAutomaticLocalInstall(buildGame, variantID: variant.id, fresh: true)
                            }
                        }.disabled(!canInstall)
                    }.disabled(unavailable || !compatible)
                    Button("Etapa 3 · Transferir / retomar arquivos") {
                        if model.authorizeForLocalAction(variant, recipe: recipe) {
                            model.transferLocalAPKFiles(recipe, variantID: variant.id)
                        }
                    }.disabled(unavailable || !compatible || !installEligible)
                    Button("Executar no Vision Pro") {
                        model.launchLocalAPK(recipe, variantID: variant.id)
                    }.disabled(unavailable || model.device == nil || !model.jobs.contains {
                        $0.recipe.id == recipe.id && $0.request.localAPKVariantID == variant.id
                            && $0.state == .finished && $0.completed.contains(.stage)
                    })
                    if recipe.localExperimental != nil {
                        Text("Receita local não verificada. Instalação experimental exige APK e conteúdo local válidos, runtime íntegro e assinatura Apple compatível com o dispositivo. Não exige conta ou download Meta. Build bem-sucedido não comprova funcionamento do jogo; verificações internas de licença permanecem ativas.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if let installProblem {
                        Text("Instalação bloqueada: " + installProblem)
                            .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    }
                    if !compatible {
                        Text("Não é possível prosseguir: verifique os arquivos necessários e os diagnósticos.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if variant.officialAPKHashMatchesRecipe != true {
                        Text("A autenticidade oficial deste arquivo não foi comprovada.").font(.caption).foregroundStyle(.secondary)
                    }
                    operationStatus(recipe, variantID: variant.id)
                    ForEach(model.functionalityInstallations(variant, recipe: recipe)) { receipt in
                        FunctionalityReceiptView(receipt: receipt, variant: variant, recipe: recipe, showTechnicalDetails: false)
                    }
                    ForEach(model.unconfirmedLocalInstallations(variant, recipe: recipe)) { candidate in
                        VStack(alignment: .leading, spacing: 5) {
                            Button("Testado e funcionando") {
                                model.confirmUnrecordedLocalInstallation(candidate, variant: variant, recipe: recipe)
                            }
                            .disabled(model.verifyingLegacyFunctionality.contains("install-confirmation:\(candidate.id)"))
                            if model.verifyingLegacyFunctionality.contains("install-confirmation:\(candidate.id)") {
                                ProgressView("Verificando a instalação atual e o APK…").controlSize(.small)
                            } else {
                                Text("Instalação assinada em \(candidate.signing.installed.formatted()); confirme somente depois de testar o jogo.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    ForEach(model.legacyFunctionalityInstallations(variant, recipe: recipe)) { receipt in
                        LegacyFunctionalityView(receipt: receipt, variant: variant, recipe: recipe, showTechnicalDetails: false)
                    }
                } else {
                    Text("Selecione um APK ou uma pasta pelo botão de importação.").foregroundStyle(.secondary)
                }
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func operationStatus(_ recipe: Recipe, variantID: String) -> some View {
        if let message = model.localOperationMessages[recipe.id] {
            HStack {
                if model.localOperationWorkers[recipe.id] != nil || model.localAutomaticPlanning.contains(recipe.id) {
                    if let value = model.localOperationProgress[recipe.id], value.total > 0 {
                        ProgressView(value: Double(value.done), total: Double(value.total)).frame(maxWidth: 180)
                    } else { ProgressView().controlSize(.small) }
                }
                Text(message)
                if model.localOperationWorkers[recipe.id] != nil {
                    Button("Cancelar") { model.cancelLocalOperation(recipe) }
                }
            }.font(.callout)
        }
        if let job = model.localCardJob(recipe, variantID: variantID) {
            let active = job.id == model.runningJob || model.queued.contains(job.id)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(model.localCancellingJobs.contains(job.id) ? "Cancelamento solicitado..." : (active ? model.copyProgress[job.id]?.activity ?? jobTitle(job) : jobTitle(job)))
                    Spacer()
                    if active {
                        Button("Cancelar") { model.cancel(job) }.disabled(model.localCancellingJobs.contains(job.id))
                    }
                }
                if active {
                    if let p = model.copyProgress[job.id], let validation = p.validation, validation.total > 0 {
                        ProgressView(value: Double(validation.done), total: Double(validation.total))
                    } else if let p = model.copyProgress[job.id], p.total > 0 {
                        ProgressView(value: Double(p.done), total: Double(p.total))
                    } else { ProgressView().controlSize(.small) }
                    Text("Etapas concluídas: \(job.completed.count) de \(job.steps.count)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func jobTitle(_ job: Job) -> String {
        switch job.state {
        case .cancelled: return "Trabalho cancelado"
        case .failed: return "Trabalho interrompido. Consulte os diagnósticos."
        case .finished: return job.steps.contains(.buildOnly) ? "Compilação concluída · aplicativo no Mac" : (job.completed.contains(.stage) ? "Arquivos verificados no Vision Pro" : "Aplicativo instalado · transferência pendente")
        case .waiting: return "Na fila"
        case .running:
            switch job.current {
            case .fetch: return "Verificando arquivos..."
            case .buildOnly: return "Preparando e compilando..."
            case .build: return "Preparando, compilando e assinando..."
            case .stage: return "Transferindo dados para o Vision Pro..."
            default: return "Trabalho em andamento..."
            }
        }
    }

    private var advancedSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let recipe, let variant = variant(recipe) {
                LocalBundleIdentityControls(recipe: recipe, variantID: variant.id)
            }
            GroupBox("Assinatura Apple") {
                LocalAppleSigningControls().padding(6)
            }
            Text("A identidade e o perfil Apple são escolhidos automaticamente a partir da instalação existente e da compilação verificada. Substituir um aplicativo exige confirmação; nenhum aplicativo é removido.")
                .font(.caption).foregroundStyle(.secondary)
            GroupBox("Escolha manual de receita") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Usar a receita selecionada na próxima importação", isOn: $model.localManualRecipeSelection)
                    Picker("Receita", selection: $model.selectedLocalRecipeID) {
                    ForEach(model.localRecipes, id: \.id) { Text("\($0.title) · \($0.versionName)").tag($0.id) }
                    }
                }.padding(6)
            }
            GroupBox("Opções especiais") {
                VStack(alignment: .leading, spacing: 8) {
                    if let recipe, let variant = variant(recipe) {
                        Picker("Arquivo importado", selection: Binding(get: { selectedVariants[recipe.id] ?? variant.id }, set: { selectedVariants[recipe.id] = $0 })) {
                            ForEach(model.localAPKVariants(for: recipe)) { Text("\($0.id) · \($0.registeredAt.formatted())").tag($0.id) }
                        }
                    }
                    Toggle("Medição do ambiente em novos builds", isOn: $model.roomMeasuringForNewGames)
                    TextField("Idioma do jogo", text: $model.gameLanguageForNewGames).textFieldStyle(.roundedBorder)
                }.padding(6)
            }
            GroupBox("Logs e diagnósticos") {
                VStack(alignment: .leading, spacing: 8) {
                    if let recipe, let variant = variant(recipe) {
                        Text("\(recipe.package) · versionCode \(variant.versionCode)")
                        Text("APK SHA-256: \(variant.sha256)")
                        Text("Assinatura Android: \(variant.androidSignature?.state ?? "não verificada")")
                        if let detail = variant.androidSignature?.detail { Text(detail) }
                        Text(model.localVariantStatus(variant, recipe: recipe))
                        if let missing = variant.missingRequiredFiles, !missing.isEmpty { Text("Arquivos ausentes: \(missing.joined(separator: ", "))") }
                        Button("Validação completa (sem cache)") { model.validateLocalAPKVariant(recipe, id: variant.id) }
                            .disabled(model.localOperationWorkers[recipe.id] != nil || model.isBusy(recipe.id))
                        ForEach(model.functionalityInstallations(variant, recipe: recipe)) { receipt in
                            FunctionalityReceiptDetailsView(receipt: receipt, variant: variant, recipe: recipe)
                        }
                        if let learning = model.localLearning(recipe) {
                            Text("\(learning.current?.hashes.count ?? 0) hashes locais salvos · \(learning.installations.count) instalações no histórico")
                        }
                        if let job = model.localCardJob(recipe, variantID: variant.id) {
                            Text("Job \(job.id) · \(job.state.rawValue)")
                            if let failure = job.failure { Text(failure) }
                            Text(model.log(for: job.id).suffix(30).joined(separator: "\n"))
                        }
                    }
                    if let recipe, let diagnostic = model.localOperationDiagnostics[recipe.id] { Text(diagnostic) }
                    if let diagnostic = model.localImportDiagnostic { Text(diagnostic) }
                    if let problem = model.localRecipeLoadError { Text(problem) }
                }.font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
        }
    }
}

/// Reads only local artwork. A cache miss never schedules a network request.
struct LocalLibraryCover: View {
    @EnvironmentObject var model: AppModel
    let recipe: Recipe
    @State private var artwork: NSImage?
    var body: some View {
        ZStack {
            Color.accentColor.opacity(0.12)
            if let artwork { Image(nsImage: artwork).resizable().scaledToFill() }
            else { Image(systemName: "gamecontroller.fill").font(.largeTitle).foregroundStyle(Color.accentColor) }
        }.clipped().accessibilityLabel("Capa de \(recipe.title)")
            .task(id: recipe.id) {
                if let image = model.localGame(for: recipe).cover { artwork = image; return }
                let store = model.paths.store
                let data: Data? = await Task.detached { () -> Data? in
                    if let bytes = try? Data(contentsOf: Toolchain.storeCoverURL(store: store, recipe: recipe)) { return bytes }
                    if let id = recipe.catalogAppId {
                        if let bytes = CoverCache().cached(appId: id) { return bytes }
                        return try? Data(contentsOf: DataLocation.base.appendingPathComponent("covers/\(id).jpg"))
                    }
                    return nil as Data?
                }.value
                if !Task.isCancelled { artwork = data.flatMap(NSImage.init(data:)) }
            }
    }
}

/// Restores the 131/132 signing controls using the existing model and discovery flow.
/// Rendering this section never changes a team or triggers a connection probe.
struct LocalAppleSigningControls: View {
    @EnvironmentObject var model: AppModel

    static func connectionDetail(device: Device?, problem: String?, refreshing: Bool, count: Int) -> String {
        if refreshing { return "Verificando conexão com o Vision Pro…" }
        if let problem { return problem }
        guard let device else {
            return count > 1 ? "Vários Vision Pro identificados. Escolha o dispositivo abaixo." : "Vision Pro não conectado ou não acessível."
        }
        guard device.paired else { return "Vision Pro identificado, mas não emparelhado com este Mac." }
        guard device.reachable else { return "Vision Pro identificado, mas não acessível." }
        guard device.developerMode else { return "Vision Pro acessível; ative o Modo de Desenvolvedor para instalar." }
        let transport = device.transport.map { " via \($0.text)" } ?? ""
        return device.connected ? "Vision Pro conectado\(transport)." : "Vision Pro acessível\(transport); conexão em espera."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Team ID", text: $model.teamId).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                Menu(L("Choose from Xcode", "Aus Xcode auswählen")) {
                    ForEach(model.teamCandidates) { team in
                        Button("\(team.name) · \(team.id)") { model.teamId = team.id }
                    }
                }.disabled(model.teamCandidates.isEmpty)
            }
            if model.teamCandidates.isEmpty {
                Text(L("Sign in to your Apple ID in Xcode › Settings › Accounts, then refresh this page.",
                       "Melde deine Apple-ID in Xcode › Einstellungen › Accounts an und aktualisiere diese Seite."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                DeviceChip()
                Button(L("Check headset", "Headset prüfen"), systemImage: "arrow.clockwise") { model.refresh() }
                    .disabled(model.refreshing)
            }
            if let device = model.device {
                Text("UDID: \(device.udid)").font(.caption.monospaced()).textSelection(.enabled)
                Text("\(device.name) · visionOS \(device.osVersion)").font(.caption)
            }
            if model.refreshing { ProgressView().controlSize(.small) }
            Text(Self.connectionDetail(device: model.device, problem: model.deviceProblem,
                                       refreshing: model.refreshing, count: model.devices.count))
                .font(.callout).foregroundStyle(model.deviceProblem == nil ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
            if model.devices.count > 1 {
                Picker(L("Use this one", "Dieses benutzen"), selection: Binding(
                    get: { model.device?.udid ?? "" }, set: { model.chosenDevice = $0; model.refresh() })) {
                    if model.device == nil { Text(L("Choose…", "Auswählen…")).tag("") }
                    ForEach(model.devices, id: \.udid) { device in
                        Text("\(device.name) · \(device.udid)").tag(device.udid)
                    }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Editing and saving declarations do not depend on runtime availability or build readiness.
struct ExperimentalIdentityEditor185: View {
    @Binding var appID: String
    @Binding var provenance: String
    let save: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Meta AppID real", text: $appID)
                .textFieldStyle(.roundedBorder).accessibilityIdentifier("experimental185.appID")
            TextField("Fonte verificável do AppID", text: $provenance)
                .textFieldStyle(.roundedBorder).accessibilityIdentifier("experimental185.provenance")
            Button("Salvar receita experimental · rascunho", action: save)
                .accessibilityIdentifier("experimental185.save")
        }
    }
}
