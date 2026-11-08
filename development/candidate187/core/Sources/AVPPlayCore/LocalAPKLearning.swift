import Foundation
import Darwin

public enum LocalAPKStatus: String, Sendable {
    case original = "APK original da receita"
    case recognized = "APK local reconhecido"
    case unverified = "APK local ainda não verificado"
    case incompatible = "APK incompatível"
    case installed = "Variante instalada com sucesso"
}

public struct LocalAPKInstallation: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var variantID: String
    public var sha256: String
    public var size: Int64
    public var package: String
    public var versionCode: String
    public var bundleID: String
    public var deviceID: String
    public var team: String
    public var toolchain: String
    public var date: Date
    /// Absent on legacy receipts; never infer settings from the app's current preferences.
    public var gameTitle: String?
    public var recipeID: String?
    public var build: LocalAPKBuildEvidence?
    public var configuration: InstallRequest?
    public var legacyRecovery: LegacyFunctionalityEvidence?
    public var jobID: String?
    public var confirmationStatus: String?
    public var confirmedAt: Date?
    public var revokedAt: Date?
    public var functionalityStatus: String? {
        confirmedAt != nil && revokedAt == nil ? "funcionamento confirmado pelo usuário" : nil
    }
}

/// A versioned overlay, not a replacement for the publisher recipe. Every revision is retained.
public struct LocalAPKRecipeRevision: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var date: Date
    public var hashes: [String: Int64]
    public var preferredHash: String?
    public var restoredFrom: String?
}

public struct LocalAPKLearningRecord: Codable, Sendable, Equatable {
    public var recipeID: String
    public var authorizedHashes: Set<String> = []
    public var installations: [LocalAPKInstallation] = []
    public var revisions: [LocalAPKRecipeRevision] = []
    public var current: LocalAPKRecipeRevision? { revisions.last }
}

public struct LocalAPKLearningStore: Sendable {
    private static let lock = NSRecursiveLock()
    public let root: URL
    public init(variants: LocalAPKVariantStore = LocalAPKVariantStore()) {
        root = variants.root.appendingPathComponent("learned-recipes", isDirectory: true)
    }
    private func url(_ recipe: Recipe) throws -> URL {
        guard Recipe.isSafeName(recipe.id) else { throw LocalAPKVariantError.unsafePath(recipe.id) }
        return root.appendingPathComponent("\(recipe.id)-\(recipe.versionCode).json")
    }
    public func load(_ recipe: Recipe) throws -> LocalAPKLearningRecord {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let file = try url(recipe)
        guard FileManager.default.fileExists(atPath: file.path) else { return LocalAPKLearningRecord(recipeID: recipe.id) }
        let record = try JSONDecoder().decode(LocalAPKLearningRecord.self, from: Data(contentsOf: file))
        guard record.recipeID == recipe.id else { throw LocalAPKVariantError.recipeMismatch(recipe.id) }
        return record
    }
    private func acquireWriteLock() throws -> Int32 {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw LocalAPKVariantError.unsafePath(root.path)
        }
        let fd = open(root.appendingPathComponent(".write.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw LocalAPKVariantError.invalidRecord("Cannot lock local recipe storage") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw LocalAPKVariantError.invalidRecord("Local recipe is being updated by another process; retry.")
        }
        return fd
    }
    private func save(_ record: LocalAPKLearningRecord, recipe: Recipe) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let file = try url(recipe)
        // Keep the exact previous record for audited recovery; never overwrite a backup.
        if FileManager.default.fileExists(atPath: file.path) {
            let backups = root.appendingPathComponent("audit-backups", isDirectory: true)
            try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.copyItem(at: file, to: backups.appendingPathComponent("\(file.lastPathComponent).\(UUID().uuidString).json"))
        }
        try encoder.encode(record).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    public func authorize(_ variant: LocalAPKVariant, recipe: Recipe, allowed: Bool) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let fd = try acquireWriteLock(); defer { flock(fd, LOCK_UN); close(fd) }
        try identity(variant, recipe: recipe)
        var record = try load(recipe)
        if allowed { record.authorizedHashes.insert(variant.sha256) } else { record.authorizedHashes.remove(variant.sha256) }
        try save(record, recipe: recipe)
    }
    private func identity(_ variant: LocalAPKVariant, recipe: Recipe) throws {
        guard variant.recipeID == recipe.id, variant.recipeVersionCode == recipe.versionCode,
              variant.package == recipe.package, variant.versionCode == String(recipe.versionCode),
              variant.sha256.count == 64, variant.sha256.allSatisfy({ $0.isHexDigit }), variant.size > 0 else {
            throw LocalAPKVariantError.recipeMismatch(recipe.id)
        }
    }
    public func requireAuthorized(_ variant: LocalAPKVariant, recipe: Recipe) throws {
        try identity(variant, recipe: recipe)
        guard try load(recipe).authorizedHashes.contains(variant.sha256) else {
            throw LocalAPKVariantError.invalidRecord("Confirm authorized use of this exact local APK in Local Library first.")
        }
    }
    /// Stage verifies an existing installation; its transfer Job is not a new install owner.
    /// Reuse only the persisted owner of this exact receipt ID. The strict writer below
    /// still checks every other field and preserves historical testimony without writes.
    func recordInstallationAfterStage(_ receipt: LocalAPKInstallation,
                                      variant: LocalAPKVariant, recipe: Recipe) throws -> LocalAPKInstallation {
        let existing = try load(recipe).installations.first { $0.id == receipt.id }
        var associated = receipt
        if let existing { associated.jobID = existing.jobID }
        try recordInstallation(associated, variant: variant, recipe: recipe)
        return existing ?? associated
    }

    public func recordInstallation(_ receipt: LocalAPKInstallation, variant: LocalAPKVariant, recipe: Recipe) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let fd = try acquireWriteLock(); defer { flock(fd, LOCK_UN); close(fd) }
        try requireAuthorized(variant, recipe: recipe)
        guard receipt.sha256 == variant.sha256, receipt.size == variant.size, receipt.variantID == variant.id,
              receipt.package == variant.package, receipt.versionCode == variant.versionCode,
              !receipt.bundleID.isEmpty, !receipt.deviceID.isEmpty, !receipt.team.isEmpty, !receipt.toolchain.isEmpty else {
            throw LocalAPKVariantError.invalidRecord("Installation receipt does not match the selected APK.")
        }
        if let build = receipt.build, let configuration = receipt.configuration {
            guard configuration.localAPKVariantID == receipt.variantID, configuration.bundleId == receipt.bundleID,
                  configuration.device == receipt.deviceID, configuration.team == receipt.team,
                  build.recipeSHA256 == (try LocalAPKBuildEvidence.recipeHash(recipe)),
                  build.assetsSHA256 == (try LocalAPKBuildEvidence.assetsHash(variant)),
                  [build.signedBuildSHA256, build.unsignedBuildSHA256].allSatisfy({ $0.count == 64 && $0.allSatisfy(\.isHexDigit) }) else {
                throw LocalAPKVariantError.invalidRecord("A configuração do build não corresponde à instalação.")
            }
        } else if receipt.build != nil || receipt.configuration != nil {
            throw LocalAPKVariantError.invalidRecord("Registro de configuração incompleto.")
        }
        var record = try load(recipe)
        if let old = record.installations.first(where: { $0.id == receipt.id }) {
            // Resume may repeat the same receipt, but must never replace its identity or testimony.
            var unchanged = old
            unchanged.confirmationStatus = nil; unchanged.confirmedAt = nil; unchanged.revokedAt = nil
            guard unchanged == receipt else {
                let encoder = JSONEncoder()
                let original = try JSONSerialization.jsonObject(with: encoder.encode(unchanged)) as! [String: Any]
                let attempted = try JSONSerialization.jsonObject(with: encoder.encode(receipt)) as! [String: Any]
                let differences = Set(original.keys).union(attempted.keys).filter { key in
                    let lhs = original[key] as? NSObject
                    let rhs = attempted[key] as? NSObject
                    return lhs?.isEqual(rhs) != true
                }.sorted().joined(separator: ", ")
                throw LocalAPKVariantError.invalidRecord("O identificador já pertence a outra instalação; histórico preservado. ID=\(receipt.id); Job proprietário=\(old.jobID ?? "legado sem Job"); Job solicitado=\(receipt.jobID ?? "ausente"); campos divergentes=\(differences).")
            }
            return
        }
        guard receipt.confirmedAt == nil, receipt.revokedAt == nil, receipt.confirmationStatus == nil else {
            throw LocalAPKVariantError.invalidRecord("Uma nova instalação deve começar sem confirmação de funcionamento.")
        }
        record.installations.append(receipt)
        try save(record, recipe: recipe)
    }
    public func latestInstallations(variant: LocalAPKVariant, recipe: Recipe) throws -> [LocalAPKInstallation] {
        let record = try load(recipe)
        var seen: Set<String> = []
        return record.installations.reversed().filter { receipt in
            let destination = receipt.deviceID + ":" + receipt.bundleID
            guard seen.insert(destination).inserted else { return false }
            return receipt.variantID == variant.id && receipt.sha256 == variant.sha256 && receipt.size == variant.size
                && receipt.build?.recipeSHA256 == (try? LocalAPKBuildEvidence.recipeHash(recipe))
                && receipt.build?.assetsSHA256 == (try? LocalAPKBuildEvidence.assetsHash(variant))
        }
    }

    /// Historical testimony matches the APK identity, not the current dependency manifest.
    /// This read-only result must never authorize preparation or installation.
    public func historicalConfirmations(variant: LocalAPKVariant, recipe: Recipe) throws -> [LocalAPKInstallation] {
        try load(recipe).installations.filter {
            $0.functionalityStatus != nil && $0.variantID == variant.id
                && $0.sha256 == variant.sha256 && $0.size == variant.size
                && $0.package == variant.package && $0.versionCode == variant.versionCode
                && ($0.recipeID == nil || $0.recipeID == recipe.id)
        }
    }

    public func confirmationPresentation(variant: LocalAPKVariant, recipe: Recipe) throws -> String? {
        if try latestInstallations(variant: variant, recipe: recipe).contains(where: { $0.functionalityStatus != nil }) {
            return "Funcionamento confirmado"
        }
        if try !historicalConfirmations(variant: variant, recipe: recipe).isEmpty {
            return "Funcionamento confirmado anteriormente"
        }
        return nil
    }

    /// The caller must obtain a fresh read-only recovery proposal before the user's confirmation.
    /// Upgrade this exact old receipt atomically; never rewrite its Job or create another installation.
    public func confirmRecoveredInstallation(_ recovered: LocalAPKInstallation, variant: LocalAPKVariant,
                                            recipe: Recipe, now: Date = Date(), saveConfirmedHash: Bool = true) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let fd = try acquireWriteLock(); defer { flock(fd, LOCK_UN); close(fd) }
        try identity(variant, recipe: recipe)
        var record = try load(recipe)
        guard let recovery = recovered.legacyRecovery,
              let index = record.installations.firstIndex(where: { $0.id == recovered.id }),
              record.installations[index].build == nil, record.installations[index].configuration == nil,
              try LocalAPKBuildEvidence.digest(record.installations[index]) == recovery.originalReceiptSHA256,
              recovered.variantID == variant.id, recovered.sha256 == variant.sha256, recovered.size == variant.size,
              recovered.package == variant.package, recovered.versionCode == variant.versionCode,
              let build = recovered.build, let configuration = recovered.configuration,
              configuration.bundleId == recovered.bundleID, configuration.device == recovered.deviceID,
              configuration.team == recovered.team, configuration.localAPKVariantID == variant.id,
              build.recipeSHA256 == (try LocalAPKBuildEvidence.recipeHash(recipe)),
              build.assetsSHA256 == (try LocalAPKBuildEvidence.assetsHash(variant)),
              recovered.confirmedAt == nil, recovered.revokedAt == nil else {
            throw LocalAPKVariantError.invalidRecord("A evidência recuperada ou o recibo original mudou; verifique novamente.")
        }
        let old = record.installations[index]
        guard recovered.date == old.date && recovered.bundleID == old.bundleID && recovered.deviceID == old.deviceID
            && recovered.team == old.team && recovered.toolchain == old.toolchain
            && recovered.variantID == old.variantID && recovered.sha256 == old.sha256 && recovered.size == old.size
            && recovered.package == old.package && recovered.versionCode == old.versionCode
            && [build.signedBuildSHA256, build.unsignedBuildSHA256].allSatisfy({ $0.count == 64 && $0.allSatisfy(\.isHexDigit) }) else {
            throw LocalAPKVariantError.invalidRecord("A recuperação não pode alterar a identidade da instalação anterior.")
        }
        var confirmed = recovered
        confirmed.confirmedAt = now; confirmed.confirmationStatus = "funcionamento confirmado pelo usuário"
        record.installations[index] = confirmed
        if saveConfirmedHash { appendConfirmedHash(variant, to: &record, now: now) }
        try save(record, recipe: recipe)
    }

    public func legacyInstallations(variant: LocalAPKVariant, recipe: Recipe) throws -> [LocalAPKInstallation] {
        var seen: Set<String> = []
        return try load(recipe).installations.reversed().filter {
            guard seen.insert($0.deviceID + ":" + $0.bundleID).inserted else { return false }
            return $0.variantID == variant.id && $0.sha256 == variant.sha256 && $0.size == variant.size
                && $0.build == nil && $0.configuration == nil
        }
    }

    /// User testimony applies only to this completed receipt, never to the APK name or another installation.
    public func setFunctionality(receiptID: String, variant: LocalAPKVariant, recipe: Recipe,
                                 confirmed: Bool, now: Date = Date(), saveConfirmedHash: Bool = false) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let fd = try acquireWriteLock(); defer { flock(fd, LOCK_UN); close(fd) }
        try identity(variant, recipe: recipe)
        var record = try load(recipe)
        guard let index = record.installations.firstIndex(where: {
            $0.id == receiptID && $0.variantID == variant.id && $0.sha256 == variant.sha256
                && $0.size == variant.size && $0.package == variant.package && $0.versionCode == variant.versionCode
        }) else { throw LocalAPKVariantError.invalidRecord("A instalação concluída não corresponde a esta variante.") }
        // Legacy receipts have no reliable build configuration. Keep them visible as technical history only.
        guard record.installations[index].build != nil, record.installations[index].configuration != nil else {
            throw LocalAPKVariantError.invalidRecord("Este recibo antigo não contém a configuração instalada; não é possível inferi-la com segurança.")
        }
        if confirmed {
            guard record.installations[index].build?.recipeSHA256 == (try LocalAPKBuildEvidence.recipeHash(recipe)),
                  record.installations[index].build?.assetsSHA256 == (try LocalAPKBuildEvidence.assetsHash(variant)) else {
                throw LocalAPKVariantError.invalidRecord("A receita ou os arquivos mudaram; preserve a confirmação histórica e teste uma nova instalação.")
            }
            record.installations[index].confirmationStatus = "funcionamento confirmado pelo usuário"
            record.installations[index].confirmedAt = now
            record.installations[index].revokedAt = nil
            if saveConfirmedHash { appendConfirmedHash(variant, to: &record, now: now) }
        } else {
            record.installations[index].confirmationStatus = "confirmação revogada pelo usuário"
            record.installations[index].revokedAt = now
        }
        try save(record, recipe: recipe)
    }

    private func appendConfirmedHash(_ variant: LocalAPKVariant, to record: inout LocalAPKLearningRecord, now: Date) {
        var hashes = record.current?.hashes ?? [:]
        hashes[variant.sha256] = variant.size
        record.revisions.append(LocalAPKRecipeRevision(id: UUID().uuidString, date: now, hashes: hashes,
                                                      preferredHash: variant.sha256, restoredFrom: nil))
    }

    /// One user action: fresh full integrity and Android signature verification, then one atomic record write.
    public func confirmVerifiedFunctionality(receiptID: String, variant: LocalAPKVariant, recipe: Recipe,
                                             variants: LocalAPKVariantStore, saveHash: Bool = true) throws {
        // Confirmation is testimony about this APK and installed build. Rehash the APK itself, but do not
        // reread large external OBB/data files merely to record testimony or an APK hash preference.
        let checked = try variants.validated(id: variant.id, for: recipe, verifyAssetHashes: false, forceFull: true)
        guard checked.variant == variant, try AndroidAPKSignature.inspect(checked.apk).verified else {
            throw LocalAPKVariantError.invalidRecord("O APK mudou ou sua assinatura Android não foi verificada.")
        }
        try requireAuthorized(variant, recipe: recipe)
        try setFunctionality(receiptID: receiptID, variant: variant, recipe: recipe, confirmed: true, saveConfirmedHash: saveHash)
    }

    /// Later opt-in preserves the original testimony date and installed configuration.
    public func saveVerifiedConfirmedHash(receiptID: String, variant: LocalAPKVariant, recipe: Recipe,
                                          variants: LocalAPKVariantStore) throws {
        let checked = try variants.validated(id: variant.id, for: recipe, verifyAssetHashes: false, forceFull: true)
        guard checked.variant == variant, try AndroidAPKSignature.inspect(checked.apk).verified else {
            throw LocalAPKVariantError.invalidRecord("APK alterado ou assinatura não verificada.")
        }
        _ = try confirmedConfiguration(receiptID: receiptID, variant: variant, recipe: recipe)
        try confirmLearning(variant, recipe: recipe, receiptID: receiptID)
    }

    /// A future installation must go through the normal validation, signing and staging pipeline.
    /// This returns settings only, never an integrity/signature exemption or inherited confirmation.
    public func confirmedConfiguration(receiptID: String, variant: LocalAPKVariant, recipe: Recipe) throws -> InstallRequest {
        let record = try load(recipe)
        try identity(variant, recipe: recipe)
        guard let receipt = record.installations.first(where: {
            $0.id == receiptID && $0.variantID == variant.id && $0.sha256 == variant.sha256
                && $0.size == variant.size && $0.functionalityStatus != nil
        }), let build = receipt.build, let configuration = receipt.configuration,
            build.recipeSHA256 == (try LocalAPKBuildEvidence.recipeHash(recipe)),
            build.assetsSHA256 == (try LocalAPKBuildEvidence.assetsHash(variant)) else {
            throw LocalAPKVariantError.invalidRecord("Confirmação ausente, revogada ou referente a outros arquivos/receita.")
        }
        return configuration
    }

    /// This is called only after the user confirms the displayed receipt and exact hash/size.
    public func confirmLearning(_ variant: LocalAPKVariant, recipe: Recipe, receiptID: String) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let fd = try acquireWriteLock(); defer { flock(fd, LOCK_UN); close(fd) }
        try requireAuthorized(variant, recipe: recipe)
        var record = try load(recipe)
        guard record.installations.contains(where: {
            $0.id == receiptID && $0.variantID == variant.id && $0.sha256 == variant.sha256 && $0.size == variant.size
        }) else { throw LocalAPKVariantError.invalidRecord("A completed signed installation is required before learning.") }
        var hashes = record.current?.hashes ?? [:]
        hashes[variant.sha256] = variant.size
        record.revisions.append(LocalAPKRecipeRevision(id: UUID().uuidString, date: Date(), hashes: hashes,
                                                      preferredHash: variant.sha256, restoredFrom: nil))
        try save(record, recipe: recipe)
    }
    public func restore(_ revisionID: String?, recipe: Recipe) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let fd = try acquireWriteLock(); defer { flock(fd, LOCK_UN); close(fd) }
        var record = try load(recipe)
        let previous = record.revisions.first { $0.id == revisionID }
        guard revisionID == nil || previous != nil else { throw LocalAPKVariantError.invalidRecord("Unknown revision") }
        var protectedHashes = previous?.hashes ?? [:]
        // Preserve only hashes explicitly saved in revisions. Testimony alone must never opt into hash learning.
        for revision in record.revisions { protectedHashes.merge(revision.hashes) { current, _ in current } }
        record.revisions.append(LocalAPKRecipeRevision(id: UUID().uuidString, date: Date(), hashes: protectedHashes,
                                                      preferredHash: previous?.preferredHash, restoredFrom: revisionID))
        try save(record, recipe: recipe)
    }
    public func status(_ variant: LocalAPKVariant, recipe: Recipe) throws -> LocalAPKStatus {
        if variant.package != recipe.package || variant.versionCode != String(recipe.versionCode)
            || !variant.architectures.contains("arm64-v8a") || variant.androidSignature?.state == "invalid" { return .incompatible }
        if (try? LocalAPKVariantStore.requireCompatibleDependencies(variant, recipe: recipe)) == nil {
            return .incompatible
        }
        let record = try load(recipe)
        if record.current?.hashes[variant.sha256] == variant.size { return .recognized }
        if record.installations.contains(where: { $0.sha256 == variant.sha256 && $0.size == variant.size }) { return .installed }
        if recipe.files.first(where: { $0.role == "apk" })?.sha256?.lowercased() == variant.sha256 { return .original }
        return .unverified
    }

    /// A declarative local copy for export/review. Runtime selection still uses the explicit variant
    /// and its own integrity record; the bundled recipe and dependency checks stay authoritative.
    public func personalizedRecipe(_ recipe: Recipe, variant: LocalAPKVariant) throws -> Recipe {
        try identity(variant, recipe: recipe)
        guard try load(recipe).current?.hashes[variant.sha256] == variant.size else {
            throw LocalAPKVariantError.invalidRecord("This hash has not been confirmed in the local recipe.")
        }
        var copy = recipe
        guard let index = copy.files.firstIndex(where: { $0.role == "apk" }) else { throw LocalAPKVariantError.recipeMismatch(recipe.id) }
        copy.files[index].sha256 = variant.sha256
        copy.files[index].size = variant.size
        return copy
    }
}

public extension LocalGameImport {
    /// Package identity, never a filename guess. Ambiguous recipes are presented to the caller.
    static func matchingRecipes(apk: URL, recipes: [Recipe]) throws -> [Recipe] {
        let inspection = try ApkUnpacker().inspect(apk: apk)
        let matching = recipes.filter { !$0.package.isEmpty && $0.package == inspection.package && $0.files.contains { $0.role == "apk" } }
        let exact = matching.filter { String($0.versionCode) == inspection.versionCode }
        return (exact.isEmpty ? matching : exact).sorted { $0.id < $1.id }
    }
}
