import Foundation

public enum LibraryStatus182: String, CaseIterable, Hashable, Sendable {
    case installed = "Instalado", prepared = "Preparado", pending = "Pendente", experimental = "Experimental"
}

public struct LibraryEntry182: Identifiable, Sendable {
    public var id: String
    public var title: String
    public var package: String
    public var target: String?
    public var recipe: Recipe?
    public var provisional: Bool
    public var status: LibraryStatus182
    public var evidence: String
    public var variantCount: Int
    public var jobs: [Job]
    public var sourceLabel = "Candidate"
    public var readOnly = false
    public var artworkAppID: String? = nil
    public var activeJob: Job? { jobs.first { $0.state == .running || $0.state == .waiting } }
    public var latestJob: Job? { jobs.first }

    public func matches(search: String, status filter: LibraryStatus182?) -> Bool {
        (filter == nil || filter == status) && (search.isEmpty || [title, package, target ?? "", id]
            .contains { $0.localizedCaseInsensitiveContains(search) })
    }
}

/// Local evidence projection; shipped recipes alone never create cards or installations.
/// A native-build completion alone is not evidence that mandatory Stage finished.
public enum VisualLibrary182 {
    public static func entries(recipes: [Recipe], variants: [LocalAPKVariant], jobs: [Job],
                               installations: [LocalAPKInstallation], preparedRecipeIDs: Set<String> = [],
                               provisional: [LocalProvisionalRecipe] = []) throws -> [LibraryEntry182] {
        var known = Dictionary(recipes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for job in jobs.sorted(by: { $0.updated > $1.updated }) where known[job.recipe.id] == nil {
            known[job.recipe.id] = job.recipe
        }
        var result: [LibraryEntry182] = []
        for recipe in known.values {
            let local = variants.filter { $0.recipeID == recipe.id && $0.recipeVersionCode == recipe.versionCode }
            let history = jobs.filter { $0.recipe.id == recipe.id }.sorted { $0.updated > $1.updated }
            guard !local.isEmpty || !history.isEmpty || preparedRecipeIDs.contains(recipe.id) else { continue }
            var installed = false
            for receipt in installations where receipt.recipeID == recipe.id && receipt.build != nil && receipt.configuration != nil {
                guard let variant = local.first(where: { $0.id == receipt.variantID && $0.sha256 == receipt.sha256
                    && $0.size == receipt.size && $0.package == receipt.package && $0.versionCode == receipt.versionCode }),
                    receipt.build?.recipeSHA256 == (try LocalAPKBuildEvidence.recipeHash(recipe)),
                    receipt.build?.assetsSHA256 == (try LocalAPKBuildEvidence.assetsHash(variant)) else { continue }
                let superseded = history.contains { job in
                    job.id != receipt.jobID && job.completed.contains(.build) && job.updated > receipt.date
                        && job.request.device == receipt.deviceID && job.request.bundleId == receipt.bundleID
                }
                guard !superseded else { continue }
                let staged = history.contains { job in
                    job.state == .finished && job.completed.contains(.stage) && job.updated >= receipt.date
                        && job.request.device == receipt.deviceID && job.request.bundleId == receipt.bundleID
                        && job.request.localAPKVariantID == receipt.variantID
                        && job.request.localAssetsSHA256 == receipt.build?.assetsSHA256
                }
                // This label describes persisted evidence, never a live headset probe.
                installed = installed || staged || receipt.functionalityStatus != nil
            }
            let experimental = recipe.localExperimental != nil
            let prepared = preparedRecipeIDs.contains(recipe.id) || history.contains {
                $0.state == .finished && $0.completed.contains(.buildOnly)
            }
            let status: LibraryStatus182 = experimental ? .experimental : installed ? .installed : prepared ? .prepared : .pending
            result.append(LibraryEntry182(id: recipe.id, title: recipe.title, package: recipe.package,
                target: KleptonRecipeCompatibility.resolve(recipe).toolchain.target, recipe: recipe, provisional: false,
                status: status, evidence: installed ? "Instalação registrada localmente; sem consulta ao headset"
                    : prepared ? "Preparação/build registrado; artefato será revalidado antes de uso"
                    : "Importação ou Job local; instalação completa não comprovada",
                variantCount: local.count, jobs: history))
        }
        for record in provisional where !result.contains(where: { $0.package == record.package }) {
            let community = record.communityTarget.flatMap { candidate -> CommunityKleptonTarget? in
                guard candidate.packageID == record.package, candidate.versionCode == record.versionCode,
                      record.versionName == nil || record.versionName == candidate.versionName else { return nil }
                return candidate
            }
            result.append(LibraryEntry182(id: record.id, title: community?.title ?? record.title, package: record.package,
                target: record.experimentalTarget?.target ?? community?.target, recipe: nil,
                provisional: true, status: .experimental, evidence: "APK provisório importado; compatibilidade não comprovada",
                variantCount: 1, jobs: [], artworkAppID: community?.appID))
        }
        for variant in variants where !result.contains(where: { $0.id == variant.recipeID || $0.package == variant.package }) {
            result.append(LibraryEntry182(id: variant.recipeID, title: known[variant.recipeID]?.title ?? variant.package, package: variant.package,
                target: nil, recipe: nil, provisional: false, status: .pending,
                evidence: "Variante importada sem receita correspondente; nenhuma instalação inferida",
                variantCount: variants.filter { $0.recipeID == variant.recipeID }.count, jobs: []))
        }
        return result.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    public static func load(recipes directory: URL, variants registry: LocalAPKVariantStore,
                            jobs store: JobStore, preparedRoot: URL, provisionalRoot: URL) throws -> [LibraryEntry182] {
        let jobs = store.all()
        let provisional = try LocalProvisionalRecipeStore(root: provisionalRoot).loadAll()
        let shipped = try RecipeStore(directory: directory).loadAll()
        let combined = shipped + provisional.compactMap { $0.experimentalRecipe ?? $0.communityRecipe }
        var recipes = Dictionary(combined.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var frozen = Set<String>()
        for job in jobs.sorted(by: { $0.updated > $1.updated }) {
            if job.request.localAPKVariantID != nil, frozen.insert(job.recipe.id).inserted { recipes[job.recipe.id] = job.recipe }
            else if recipes[job.recipe.id] == nil { recipes[job.recipe.id] = job.recipe }
        }
        let folders = (try? FileManager.default.contentsOfDirectory(at: registry.root, includingPropertiesForKeys: nil)) ?? []
        let variants: [LocalAPKVariant] = folders.flatMap { folder -> [LocalAPKVariant] in
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            return files.filter { $0.pathExtension == "json" }.compactMap {
                guard let data = try? Data(contentsOf: $0) else { return nil }
                return try? JSONDecoder().decode(LocalAPKVariant.self, from: data)
            }
        }
        var installations: [LocalAPKInstallation] = []
        for recipe in recipes.values { installations += try LocalAPKLearningStore(variants: registry).load(recipe).installations }
        // Inspect preparation markers only. No hashing, repair, migration or runtime extraction.
        var prepared = Set<String>()
        let roots = (try? FileManager.default.contentsOfDirectory(at: preparedRoot, includingPropertiesForKeys: nil)) ?? []
        for recipe in recipes.values where variants.contains(where: { $0.recipeID == recipe.id }) {
            let target = KleptonRecipeCompatibility.resolve(recipe).toolchain.target
            let candidates = variants.filter { $0.recipeID == recipe.id }
            if roots.contains(where: { root in
                guard let marker = try? String(contentsOf: root.appendingPathComponent(target + "/.qi-prepared"), encoding: .utf8) else { return false }
                return candidates.contains { marker.contains("local:\($0.id):\($0.sha256) ") }
            }) { prepared.insert(recipe.id) }
        }
        return try entries(recipes: Array(recipes.values), variants: variants, jobs: jobs,
                           installations: installations, preparedRecipeIDs: prepared, provisional: provisional)
    }
}


extension VisualLibrary182 {
    public struct Snapshot: Sendable {
        public var entries: [LibraryEntry182]
        public var warnings: [String]
    }

    /// Supplementary library roots are inspected without migration or repair.
    /// Grouping a game card never merges installation identities or receipts.
    static func appendReadOnly(_ extra: [LibraryEntry182], source: String, to primary: inout [LibraryEntry182]) {
        for var entry in extra {
            if let index = primary.firstIndex(where: { $0.id == entry.id && $0.package == entry.package && !$0.readOnly }) {
                primary[index].evidence += "; também há registros separados em \(source), sem unificar identidades"
                continue
            }
            entry.id = "readonly:" + source + ":" + entry.id // UI key only; persisted IDs never change.
            entry.sourceLabel = source
            entry.readOnly = true
            entry.evidence += "; origem externa somente leitura, sem migração para o Candidate"
            primary.append(entry)
        }
    }

    public static func loadWithReadOnlySources(recipes: URL, variants: LocalAPKVariantStore, jobs: JobStore,
                                               preparedRoot: URL, provisionalRoot: URL,
                                               otherRoots: [URL]) throws -> Snapshot {
        var entries = try load(recipes: recipes, variants: variants, jobs: jobs,
                               preparedRoot: preparedRoot, provisionalRoot: provisionalRoot)
        var warnings: [String] = []
        let primary = variants.root.deletingLastPathComponent().resolvingSymlinksInPath()
        for root in otherRoots where root.resolvingSymlinksInPath() != primary {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            do {
                let extra = try load(recipes: recipes, variants: LocalAPKVariantStore(root: root.appendingPathComponent("local-variants")),
                    jobs: JobStore(directory: root.appendingPathComponent("jobs")),
                    preparedRoot: root.appendingPathComponent("prepared-local"),
                    provisionalRoot: root.appendingPathComponent("provisional-recipes"))
                appendReadOnly(extra, source: root.lastPathComponent, to: &entries)
            } catch { warnings.append("Não foi possível ler \(root.lastPathComponent): \(error)") }
        }
        return Snapshot(entries: entries.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }, warnings: warnings)
    }
}
