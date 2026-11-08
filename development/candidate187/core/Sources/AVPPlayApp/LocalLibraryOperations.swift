import AppKit
import AVPPlayCore
import Foundation

struct LocalImportPresentation: Equatable {
    var isRunning = false
    var cancelRequested = false
    var sourcePath: String?
    var folderPath: String?
    var apkPath: String?
    var recipeID: String?
    var variantID: String?
    var message: String?
    var progress: LocalImportProgress?
    var canCreateProvisional = false
    var missingRequired: [String] = []
    var unmatchedFiles: [String] = []
    var ignoredFileCount = 0
}

struct LocalImportedGame: Sendable {
    let recipe: Recipe
    let variant: LocalAPKVariant
    let discovery: LocalGameImport.Discovery
}

struct LocalAdditionalFileReview: Identifiable, Sendable {
    let id: UUID
    let recipe: Recipe
    let sourceRoot: URL
    let apk: URL
    let candidates: [LocalGameImport.AdditionalFileReview]
}

extension AppModel {
    static func localBundleIdentityKey(recipeID: String, variantID: String) -> String {
        "localBundleIdentity." + recipeID + "." + variantID
    }

    func localBundleIdentity(recipeID: String, variantID: String) throws -> LocalBundleIdentity? {
        guard let data = DataLocation.preferences.data(forKey: Self.localBundleIdentityKey(recipeID: recipeID, variantID: variantID)) else { return nil }
        return try JSONDecoder().decode(LocalBundleIdentity.self, from: data)
    }

    func saveLocalBundleIdentity(_ choice: LocalBundleIdentity?, recipe: Recipe, variantID: String) throws {
        let key = Self.localBundleIdentityKey(recipeID: recipe.id, variantID: variantID)
        if let choice {
            try choice.validate(target: KleptonRecipeCompatibility.resolve(recipe).toolchain.target)
            DataLocation.preferences.set(try JSONEncoder().encode(choice), forKey: key)
        } else { DataLocation.preferences.removeObject(forKey: key) }
    }

    func startLocalImport(source: URL, recipe: Recipe? = nil, additionalSources: [URL] = [], selectedAPK: URL? = nil,
                          expectedLocalAPKHash: String? = nil, additionalDestinations: [String: String] = [:],
                          expectedAdditionalHashes: [String: String] = [:]) {
        guard localImportWorker == nil, provisionalWorker == nil else { return }
        let token = UUID(), registry = localVariantStore, recipes = localRecipes
        let directory = (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        localImportToken = token
        localImportDiagnostic = nil
        localAdditionalReviewError = nil
        localAdditionalReview = nil
        localImport = LocalImportPresentation(isRunning: true, sourcePath: source.resolvingSymlinksInPath().path,
            folderPath: (directory ? source : source.deletingLastPathComponent()).resolvingSymlinksInPath().path,
            apkPath: directory ? nil : source.resolvingSymlinksInPath().path, recipeID: recipe?.id)
        if let recipe { importingLocalGameIDs.insert(recipe.id) }
        let worker = Task.detached(priority: .userInitiated) { [weak self] () throws -> LocalImportedGame in
            let accessed = ([source] + additionalSources).map { ($0, $0.startAccessingSecurityScopedResource()) }
            defer { for (url, active) in accessed where active { url.stopAccessingSecurityScopedResource() } }
            let progress: @Sendable (LocalImportProgress) -> Void = { value in
                Task { @MainActor [weak self] in
                    guard self?.localImportToken == token, self?.localImport.isRunning == true else { return }
                    self?.localImport.progress = value
                }
            }
            let importer = LocalGameImport()
            let selectedRecipe: Recipe, apk: URL?
            if let recipe, let selectedAPK { selectedRecipe = recipe; apk = selectedAPK }
            else {
                let selection = try importer.identify(source, recipes: recipe.map { [$0] } ?? recipes,
                    learning: LocalAPKLearningStore(variants: registry), progress: progress)
                if let expectedLocalAPKHash, selection.sha256 != expectedLocalAPKHash.lowercased() {
                    throw LocalAPKVariantError.invalidRecord("O APK selecionado mudou desde a criação do registro provisório.")
                }
                selectedRecipe = selection.recipe; apk = selection.apk
            }
            try Task.checkCancellation()
            let admitted = await MainActor.run { [weak self] in
                guard let self, self.localImportToken == token,
                      !self.isBusy(selectedRecipe.id), self.localOperationWorkers[selectedRecipe.id] == nil else { return false }
                self.localImport.recipeID = selectedRecipe.id
                self.selectedLocalRecipeID = selectedRecipe.id
                self.localRecipeSelectionExplicit = false
                self.importingLocalGameIDs.insert(selectedRecipe.id)
                return true
            }
            guard admitted else { throw LocalAPKVariantError.invalidRecord("Já existe uma operação ativa para este jogo.") }
            progress(LocalImportProgress(phase: "Localizando arquivos necessários"))
            let found = try importer.discover(in: directory ? source : source.deletingLastPathComponent(),
                recipe: selectedRecipe, additionalSources: additionalSources, selectedAPK: apk)
            guard let apk = found.apk else { throw LocalAPKVariantError.missing("APK compatível não encontrado") }
            await MainActor.run { [weak self] in
                guard self?.localImportToken == token else { return }
                self?.localImport.apkPath = apk.resolvingSymlinksInPath().path
            }
            await MainActor.run { [weak self] in
                guard self?.localImportToken == token else { return }
                self?.localImport.missingRequired = found.missingRequired
            }
            guard found.missingRequired.isEmpty else {
                throw LocalAPKVariantError.invalidRecord("Arquivos obrigatórios ausentes: \(found.missingRequired.joined(separator: ", "))")
            }
            let autoDestinations = importer.automaticAdditionalDestinations(for: found, recipe: selectedRecipe)
            let variant = try importer.register(found, recipe: selectedRecipe, store: registry,
                additionalDestinations: additionalDestinations.merging(autoDestinations,
                    uniquingKeysWith: { manual, _ in manual }),
                expectedAdditionalHashes: expectedAdditionalHashes,
                automaticAdditionalPaths: Set(autoDestinations.keys).subtracting(additionalDestinations.keys), progress: progress)
            try LocalAPKVariantStore.requireCompatibleDependencies(variant, recipe: selectedRecipe)
            // Commit has completed; a late cancel must not claim that committed data was discarded.
            return LocalImportedGame(recipe: selectedRecipe, variant: variant, discovery: found)
        }
        localImportWorker = worker
        Task { [weak self] in
            let result = await worker.result
            guard let self, self.localImportToken == token else { return }
            if let id = self.localImport.recipeID { self.importingLocalGameIDs.remove(id) }
            self.localImportWorker = nil
            self.localImport.isRunning = false
            self.localImport.progress = nil
            switch result {
            case .success(let imported):
                self.localOperationMessages[imported.recipe.id] = nil
                self.selectedLocalRecipeID = imported.recipe.id
                self.localRecipeSelectionExplicit = false
                self.localImport.recipeID = imported.recipe.id
                self.localImport.folderPath = imported.discovery.root.path
                self.localImport.apkPath = imported.variant.originalAPKSourcePath
                self.localImport.variantID = imported.variant.id
                self.localImport.message = "APK importado com sucesso"
                let includedAdditionalPaths = Set((imported.variant.assets ?? []).filter { $0.isAdditional == true }.map {
                    URL(fileURLWithPath: $0.sourcePath).resolvingSymlinksInPath().standardizedFileURL.path
                })
                self.localImport.unmatchedFiles = imported.discovery.unmatchedFiles
                    .map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
                    .filter { !includedAdditionalPaths.contains($0) }
                self.localImport.ignoredFileCount = imported.discovery.ignoredFiles.count
                self.localLibraryRevision += 1
            case .failure(is CancellationError): self.localImport.message = "Importação cancelada"
            case .failure(let error):
                self.localImport.message = "Falha na importação: \(Self.shortLocalError(error))"
                if case .some(.invalidRecord(let reason)) = error as? LocalAPKVariantError,
                   reason.hasPrefix("Nenhuma receita compatível") {
                    self.localImport.canCreateProvisional = true
                    self.createAutomaticAnalysis(from: source)
                }
                self.localImportDiagnostic = "\(error)"
            }
        }
    }

    func includeOptionalLocalFiles() {
        guard !localAdditionalReviewPreparing else { return }
        guard !localImport.isRunning,
              let recipeID = localImport.recipeID,
              let recipe = localRecipes.first(where: { $0.id == recipeID }),
              let apkPath = localImport.apkPath,
              !localImport.unmatchedFiles.isEmpty else {
            localAdditionalReviewError = "Não foi possível abrir a revisão: a importação precisa estar concluída e ter arquivos pendentes."
            return
        }
        let root = localImport.folderPath.map { URL(fileURLWithPath: $0) }
            ?? localImport.sourcePath.map { URL(fileURLWithPath: $0) }.map { path in
                (try? path.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true ? path : path.deletingLastPathComponent()
            }
        guard let root else {
            localAdditionalReviewError = "Não foi possível determinar a pasta de origem do APK. Importe o APK ou a pasta novamente."
            return
        }
        let urls = localImport.unmatchedFiles.map { URL(fileURLWithPath: $0) }
        let active = root.startAccessingSecurityScopedResource()
        localAdditionalReviewError = nil
        localAdditionalReviewPreparing = true
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<[LocalGameImport.AdditionalFileReview], Error> in
                defer { if active { root.stopAccessingSecurityScopedResource() } }
                return Result { try LocalGameImport().reviewAdditionalFiles(urls, recipe: recipe) }
            }.value
            guard let self else { return }
            self.localAdditionalReviewPreparing = false
            switch result {
            case .success(let candidates):
                self.localAdditionalReview = LocalAdditionalFileReview(id: UUID(), recipe: recipe,
                    sourceRoot: root, apk: URL(fileURLWithPath: apkPath), candidates: candidates)
            case .failure(let error):
                self.localAdditionalReviewError = "Falha ao preparar revisão: \(Self.shortLocalError(error))"
            }
        }
    }

    func confirmOptionalLocalFiles(_ review: LocalAdditionalFileReview, destinations: [String: String]) throws {
        guard localAdditionalReview?.id == review.id, !localImport.isRunning,
              localImportWorker == nil, provisionalWorker == nil, !destinations.isEmpty else {
            throw LocalAPKVariantError.invalidRecord("A revisão expirou ou nenhum arquivo foi selecionado.")
        }
        let candidates = Dictionary(uniqueKeysWithValues: review.candidates.map { ($0.origin, $0) })
        guard Set(destinations.values).count == destinations.count else {
            throw LocalAPKVariantError.invalidRecord("Dois arquivos não podem usar o mesmo destino.")
        }
        let recipeDestinations = Set((review.recipe.files + (review.recipe.addons?.items ?? []).map {
            $0.asFile(dest: review.recipe.addons?.dest)
        }).compactMap(StagePlan.destination))
        for (path, destination) in destinations {
            guard let item = candidates[path], LocalGameImport.safeAdditionalDestination(destination) else {
                throw LocalAPKVariantError.invalidRecord("Arquivo ou destino inválido: \(path)")
            }
            guard !recipeDestinations.contains("Documents/\(destination)") else {
                throw LocalAPKVariantError.invalidRecord("Destino conflita com arquivo da receita: \(destination)")
            }
            _ = item // The importer rechecks this reviewed SHA-256 during registration.
        }
        let selected = destinations.keys.sorted().map(URL.init(fileURLWithPath:))
        let hashes = Dictionary(uniqueKeysWithValues: destinations.keys.compactMap { path in candidates[path].map { (path, $0.sha256) } })
        localAdditionalReview = nil
        startLocalImport(source: review.sourceRoot, recipe: review.recipe, additionalSources: selected,
            selectedAPK: review.apk, additionalDestinations: destinations, expectedAdditionalHashes: hashes)
        guard localImport.isRunning else { throw LocalAPKVariantError.invalidRecord("A nova importação não foi iniciada.") }
    }

    func addAutomaticImportAssets() {
        guard !localImport.isRunning, let path = localImport.sourcePath,
              let recipe = localRecipes.first(where: { $0.id == localImport.recipeID }),
              let apkPath = localImport.apkPath else { return }
        let panel = NSOpenPanel()
        panel.title = "Adicionar OBBs e assets necessários"
        panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        startLocalImport(source: URL(fileURLWithPath: path), recipe: recipe,
            additionalSources: panel.urls, selectedAPK: URL(fileURLWithPath: apkPath))
    }

    /// Folder imports proceed automatically only when exactly one APK can be selected.
    /// Ambiguous folders keep the original diagnostic and never choose by directory order.
    private func createAutomaticAnalysis(from source: URL) {
        createProvisionalRecipeFromAPK(source)
    }

    /// Turns an exact community-target match into a derived, local-only recipe and routes it through
    /// the normal APK registration checks. It does not run Prepare, Build, signing, or installation.
    func activateCommunityTarget(_ record: LocalProvisionalRecipe) {
        guard let recipe = record.communityRecipe else {
            localImport.message = "Target comunitário bloqueado: \((record.compatibilityBlockers).joined(separator: "; "))"
            return
        }
        guard FileManager.default.fileExists(atPath: record.apkPath) else {
            localImport.message = "O APK original não está acessível. Selecione-o novamente para verificar a identidade e integridade."
            return
        }
        if !localRecipes.contains(where: { $0.id == recipe.id }) {
            localRecipes.append(recipe)
            localRecipes.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
        selectedLocalRecipeID = recipe.id
        localRecipeSelectionExplicit = false
        startLocalImport(source: URL(fileURLWithPath: record.apkPath), recipe: recipe,
                         expectedLocalAPKHash: record.apkSHA256)
    }

    /// Persist review declarations only. Never registers/copies an APK, creates a Job or starts Prepare.
    func saveExperimentalDraft(_ record: LocalProvisionalRecipe, appID: String, provenance: String,
                               runtime: ExperimentalRuntime183 = .klepton850) {
        do {
            let store = LocalProvisionalRecipeStore(root: DataLocation.base.appendingPathComponent("provisional-recipes", isDirectory: true))
            let updated = try store.saveExperimentalDraft(appID: appID, provenance: provenance, runtime: runtime, for: record.id)
            if let index = localProvisionalRecipes.firstIndex(where: { $0.id == updated.id }) {
                localProvisionalRecipes[index] = updated
            }
            selectedLocalRecipeID = updated.id
            localRecipeSelectionExplicit = true
            localLibraryRevision += 1
            localImport.message = updated.experimentalReviewState185 + ". Nenhuma operação de build iniciada."
        } catch { localImport.message = "Não foi possível salvar o rascunho: \(Self.shortLocalError(error))" }
    }

    /// Reuses validated offline or exact online identity; manual review remains available.
    func activateAutomaticTarget(_ record: LocalProvisionalRecipe) {
        guard record.automaticTargetBlockers.isEmpty, let identity = record.automaticIdentity else {
            localImport.message = record.automaticTargetBlockers.joined(separator: "; ")
            return
        }
        activateExperimentalTarget(record, appID: identity.appID, provenance: identity.source)
    }

    /// Persists an explicitly supplied AppID/provenance pair and routes the generated recipe through
    /// the same local APK registry used by official and community recipes. No network or device call.
    func activateExperimentalTarget(_ record: LocalProvisionalRecipe, appID: String, provenance: String, runtime: ExperimentalRuntime183 = .klepton850) {
        do {
            _ = try runtime.verifiedSource(analysis: record.genericAnalysis)
            let store = LocalProvisionalRecipeStore(root: DataLocation.base.appendingPathComponent("provisional-recipes", isDirectory: true))
            let updated = try store.setExperimentalTarget(appID: appID, provenance: provenance, runtime: runtime, for: record.id)
            if let index = localProvisionalRecipes.firstIndex(where: { $0.id == updated.id }) {
                localProvisionalRecipes[index] = updated
            }
            localLibraryRevision += 1
            guard let recipe = updated.experimentalRecipe else {
                localImport.message = "Tentativa experimental bloqueada: \(updated.compatibilityBlockers.joined(separator: "; "))"
                return
            }
            if let collision = localRecipes.first(where: { $0.id == recipe.id }) {
                guard let previous = collision.localExperimental,
                      previous.apkSHA256 == updated.apkSHA256, collision.package == recipe.package,
                      collision.versionCode == recipe.versionCode, collision.toolchain.target == recipe.toolchain.target else {
                    localImport.message = "O identificador experimental colide com uma receita existente; a receita existente foi preservada."
                    return
                }
            }
            guard FileManager.default.fileExists(atPath: updated.apkPath) else {
                localImport.message = "APK original indisponível; selecione-o novamente para verificar a identidade e integridade."
                return
            }
            if let index = localRecipes.firstIndex(where: { $0.id == recipe.id }) {
                // Same exact derived APK, refreshed external-file associations; never a shipped recipe.
                localRecipes[index] = recipe
            } else {
                localRecipes.append(recipe)
                localRecipes.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            }
            if let index = localProvisionalRecipes.firstIndex(where: { $0.id == updated.id }) {
                localProvisionalRecipes[index] = updated
            }
            selectedLocalRecipeID = recipe.id
            localRecipeSelectionExplicit = false
            startLocalImport(source: URL(fileURLWithPath: updated.apkPath), recipe: recipe,
                             additionalSources: updated.externalFiles.map { URL(fileURLWithPath: $0.path) },
                             expectedLocalAPKHash: updated.apkSHA256)
        } catch {
            localImport.message = "Não foi possível criar o target experimental: \(Self.shortLocalError(error))"
        }
    }

    func createProvisionalRecipeFromAPK(_ source: URL, allowExistingRecipe: Bool = false) {
        guard !localImport.isRunning, provisionalWorker == nil else { return }
        let knownRecipes = allowExistingRecipe ? [] : localRecipes
        let store = LocalProvisionalRecipeStore(root: DataLocation.base.appendingPathComponent("provisional-recipes", isDirectory: true))
        localImport.isRunning = true; localImport.canCreateProvisional = false
        localImport.message = nil; localImport.progress = LocalImportProgress(phase: "Inspecionando APK")
        let token = UUID(); localImportToken = token
        let worker = Task.detached(priority: .userInitiated) { () throws -> LocalProvisionalRecipe in
            let active = source.startAccessingSecurityScopedResource()
            defer { if active { source.stopAccessingSecurityScopedResource() } }
            let record = try LocalGameImport().createProvisionalAnalysis(from: source,
                knownRecipes: knownRecipes, store: store, progress: { value in
                Task { @MainActor in
                    guard self.localImportToken == token else { return }
                    self.localImport.progress = value
                }
            })
            return try await store.resolveOnlineIdentity(for: record.id)
        }
        provisionalWorker = worker
        Task { [weak self] in
            let result = await worker.result
            guard let self, self.localImportToken == token else { return }
            self.provisionalWorker = nil; self.localImport.isRunning = false; self.localImport.progress = nil
            switch result {
            case .success(let record):
            localProvisionalRecipes.removeAll { $0.id == record.id }
            localProvisionalRecipes.append(record)
            localProvisionalRecipes.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            if record.experimentalDraft185 == nil, record.experimentalRecipe != nil {
                activateAutomaticTarget(record)
                return
            }
            selectedLocalRecipeID = record.id
            localRecipeSelectionExplicit = false
            localImport.recipeID = record.id
            localImport.apkPath = record.apkPath
            localImport.message = "Receita local provisória criada. O preparo permanece bloqueado até haver configuração Klepton comprovada."
            localImport.canCreateProvisional = false
            localLibraryRevision += 1
            case .failure(let error): localImport.message = "Não foi possível criar a receita provisória: \(Self.shortLocalError(error))"
            }
        }
    }

    func cancelLocalImport() {
        guard localImport.isRunning else { return }
        localImport.cancelRequested = true
        localImportWorker?.cancel()
        provisionalWorker?.cancel()
    }

    static func shortLocalError(_ error: Error) -> String {
        if let error = error as? LocalBuildRecoveryFailure { return error.message }
        if let error = error as? LocalAPKVariantError {
            switch error {
            case .missing(let path): return "Arquivo necessário não encontrado: \(URL(fileURLWithPath: path).lastPathComponent)"
            case .hashMismatch, .sizeMismatch: return "Um arquivo mudou durante a verificação."
            case .versionMismatch: return "Versão incompatível com a receita."
            case .packageMismatch, .recipeMismatch: return "Jogo incompatível com a receita."
            case .architectureMismatch: return "O APK não possui a arquitetura necessária."
            case .invalidRecord(let message): return String(message.prefix(180))
            default: return "Não foi possível verificar os arquivos selecionados."
            }
        }
        return String(error.localizedDescription.prefix(180))
    }

    func runLocalOperation(recipe: Recipe, id: String, preparing: Bool) {
        guard localOperationWorkers[recipe.id] == nil, !isBusy(recipe.id), !importingLocalGameIDs.contains(recipe.id) else { return }
        guard !preparing || (runningJob == nil && preparingLocalVariantIDs.isEmpty) else {
            localOperationMessages[recipe.id] = "Aguarde o trabalho que está usando a toolchain."
            return
        }
        let game = localGame(for: recipe)
        let toolchain = toolchain(for: game), registry = localVariantStore, content = paths.store
        if preparing && toolchain == nil {
            localOperationMessages[recipe.id] = "Toolchain compatível não disponível. Consulte Setup."
            return
        }
        if preparing { preparingLocalVariantIDs.insert(id) } else { validatingLocalVariantIDs.insert(id) }
        localOperationMessages[recipe.id] = preparing ? "Preparando..." : "Verificando arquivos..."
        let worker = Task.detached(priority: .userInitiated) { [weak self] () async throws -> String in
            let selected = try registry.validatedForPreparation(id: id, for: recipe, forceFull: !preparing, progress: { value in
                Task { @MainActor [weak self] in
                    guard self?.localOperationWorkers[recipe.id] != nil else { return }
                    self?.localOperationProgress[recipe.id] = LocalImportProgress(phase: "Verificando arquivos", done: value.done, total: value.total)
                }
            })
            if preparing, let toolchain {
                await MainActor.run { [weak self] in self?.localOperationProgress[recipe.id] = nil }
                try LocalAPKLearningStore(variants: registry).requireAuthorized(selected.variant, recipe: recipe)
                guard try AndroidAPKSignature.inspect(selected.apk).verified else {
                    throw LocalAPKVariantError.invalidRecord("Assinatura Android não verificada.")
                }
                guard toolchain.satisfies(minCommit: recipe.toolchain.minCommit) else {
                    throw ToolchainError.tooOld(have: toolchain.commit(), need: recipe.toolchain.minCommit)
                }
                var lock = ProcessLock.acquire(ProcessLock.installURL)
                while lock == nil {
                    try await Task.sleep(for: .milliseconds(100))
                    lock = ProcessLock.acquire(ProcessLock.installURL)
                }
                defer { lock?.release() }
                try Task.checkCancellation()
                _ = try LocalAPKPreparer().prepareIsolated(recipe: recipe, variantID: id, store: content,
                                                    toolchain: toolchain, localVariants: registry, verifyAssetHashes: false)
                return "Preparação concluída"
            }
            return "Verificação concluída"
        }
        localOperationWorkers[recipe.id] = worker
        Task { [weak self] in
            let result = await worker.result
            guard let self else { return }
            self.localOperationWorkers[recipe.id] = nil
            self.localOperationProgress[recipe.id] = nil
            self.preparingLocalVariantIDs.remove(id); self.validatingLocalVariantIDs.remove(id)
            switch result {
            case .success(let message): self.localOperationMessages[recipe.id] = message
            case .failure(is CancellationError): self.localOperationMessages[recipe.id] = "Operação cancelada"
            case .failure(let error): self.localOperationMessages[recipe.id] = "Falha: \(Self.shortLocalError(error))"
            }
            let diagnostic: String
            switch result {
            case .success(let message): diagnostic = message
            case .failure(let error): diagnostic = "\(error)"
            }
            let logs = registry.root.appendingPathComponent(".operation-logs", isDirectory: true)
            let logURL = logs.appendingPathComponent("\(recipe.id)-\(UUID().uuidString).log")
            do {
                try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
                try "\(Date().ISO8601Format()) · \(preparing ? "Prepare" : "Validação")\n\(diagnostic)\n".write(to: logURL, atomically: true, encoding: .utf8)
                self.localOperationDiagnostics[recipe.id] = "\(diagnostic)\nLog: \(logURL.path)"
            } catch { self.localOperationDiagnostics[recipe.id] = diagnostic }
            self.localLibraryRevision += 1
            self.pump()
        }
    }

    func cancelLocalOperation(_ recipe: Recipe) {
        guard let worker = localOperationWorkers[recipe.id] else { return }
        localOperationMessages[recipe.id] = "Cancelamento solicitado..."
        worker.cancel()
    }

    func authorizeForLocalAction(_ variant: LocalAPKVariant, recipe: Recipe) -> Bool {
        if localLearning(recipe)?.authorizedHashes.contains(variant.sha256) != true {
            authorizeLocalVariant(variant, recipe: recipe)
        }
        return localLearning(recipe)?.authorizedHashes.contains(variant.sha256) == true
    }

    var localLibraryGames: [Recipe] {
        var seen: Set<String> = []
        return visibleLocalRecipes.filter { seen.insert($0.package.isEmpty ? $0.id : $0.package).inserted }
    }

    func localCardJob(_ recipe: Recipe, variantID: String? = nil) -> Job? {
        let matches = jobs.filter { $0.recipe.id == recipe.id && $0.request.localAPKVariantID != nil && (variantID == nil || $0.request.localAPKVariantID == variantID) }
        return matches.first { $0.id == runningJob || queued.contains($0.id) }
            ?? matches.sorted { $0.updated > $1.updated }.first
    }
}
