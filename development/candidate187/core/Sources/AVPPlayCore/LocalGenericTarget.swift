import Foundation

/// The engine shapes recognized by the pinned Klepton 850 generic target resolver.
public enum LocalGenericEngine: String, Codable, Sendable, CaseIterable {
    case unreal4
    case unreal
    case unity
    case sdl2
    case nativeActivity
}

public struct LocalGenericTargetAnalysis: Codable, Sendable, Equatable {
    public let engine: LocalGenericEngine?
    /// Klepton's target table uses this value with the `lib` prefix and without the `.so` suffix.
    public let entrypoint: String?
    /// Native libraries observed in `lib/arm64-v8a`; this is evidence, not a dependency closure.
    public let nativeLibraries: [String]
    public let blockers: [String]

    public var canAttemptGenericBuild: Bool { blockers.isEmpty && engine != nil && entrypoint != nil }

    public static func inspect(_ apk: ApkUnpacker.Inspection) -> Self {
        analyze(package: apk.package, versionCode: apk.versionCode, architectures: apk.architectures,
                nativeLibraries: apk.nativeLibraries, hasNativeActivity: apk.hasNativeActivity,
                nativeActivityLibrary: apk.nativeActivityLibrary)
    }

    public static func analyze(package: String?, versionCode: String?, architectures: Set<String>,
                               nativeLibraries: [String], hasNativeActivity: Bool,
                               nativeActivityLibrary: String?) -> Self {
        let libraryPaths = Set(nativeLibraries)
        let names = Set(libraryPaths.compactMap { path -> String? in
            guard path.hasPrefix("lib/arm64-v8a/"), path.hasSuffix(".so") else { return nil }
            return URL(fileURLWithPath: path).lastPathComponent
        })
        var blockers: [String] = []
        guard architectures.contains("arm64-v8a") else {
            blockers.append("APK não comprova código arm64-v8a")
            return .init(engine: nil, entrypoint: nil, nativeLibraries: nativeLibraries.sorted(), blockers: blockers)
        }

        let engine: LocalGenericEngine?
        let entrypoint: String?
        if names.contains("libUE4.so") {
            engine = .unreal4; entrypoint = "libUE4"
        } else if names.contains("libUnreal.so") {
            engine = .unreal; entrypoint = "libUnreal"
        } else if !names.isDisjoint(with: ["libil2cpp.so", "libunity.so", "libmono.so", "libmonobdwgc-2.0.so"]) {
            engine = .unity; entrypoint = "libmain"
        } else if names.contains("libSDL2.so") {
            engine = .sdl2; entrypoint = "libmain"
        } else if hasNativeActivity {
            engine = .nativeActivity
            let manifestName = nativeActivityLibrary?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let normalized = manifestName, Recipe.isSafeName(normalized) {
                entrypoint = "lib" + normalized
            } else {
                entrypoint = nil
                blockers.append("NativeActivity sem android.app.lib_name verificável")
            }
        } else {
            engine = nil; entrypoint = nil
            blockers.append("Engine não identificada pelo resolvedor selecionado; o APK não prova um entrypoint NativeActivity")
        }

        if let entrypoint {
            let libraryName = entrypoint.hasPrefix("lib") ? "\(entrypoint).so" : "lib\(entrypoint).so"
            if !names.contains(libraryName) {
                blockers.append("Biblioteca de entrypoint \(libraryName) ausente no APK arm64")
            }
        }
        if package?.isEmpty != false { blockers.append("Package ID Android ausente") }
        if Int(versionCode ?? "") == nil { blockers.append("VersionCode Android ausente ou inválido") }
        return .init(engine: engine, entrypoint: entrypoint, nativeLibraries: nativeLibraries.sorted(), blockers: blockers)
    }
}

/// User-supplied Meta App ID and its provenance. The ID is never inferred from Android's package name.
public struct LocalExperimentalTarget: Codable, Sendable, Equatable {
    public let appID: String
    public let provenance: String
    public let target: String
    public let engine: LocalGenericEngine
    public let entrypoint: String
    public let nativeLibraries: [String]
    public let toolchain: String
    public let minCommit: String

    public init(appID: String, provenance: String, analysis: LocalGenericTargetAnalysis, runtime: ExperimentalRuntime183 = .klepton850) throws {
        try runtime.requirePermitted()
        let normalizedID = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedProvenance = provenance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidAppID(normalizedID) else {
            throw LocalAPKVariantError.invalidRecord("Meta AppID deve conter de 5 a 24 dígitos; não é derivado do package ID.")
        }
        guard !normalizedProvenance.isEmpty, normalizedProvenance.count <= 500,
              !normalizedProvenance.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw LocalAPKVariantError.invalidRecord("Informe a procedência do Meta AppID (por exemplo, referência da página oficial ou catálogo local).")
        }
        guard analysis.canAttemptGenericBuild, let engine = analysis.engine, let entrypoint = analysis.entrypoint else {
            throw LocalAPKVariantError.invalidRecord(analysis.blockers.joined(separator: "; "))
        }
        self.appID = normalizedID
        self.provenance = normalizedProvenance
        target = DraftRecipe.genericTarget(appId: normalizedID)
        self.engine = engine
        self.entrypoint = entrypoint
        nativeLibraries = analysis.nativeLibraries
        toolchain = runtime.rawValue
        minCommit = runtime.minCommit
    }

    public static func isValidAppID(_ value: String) -> Bool {
        (5...24).contains(value.count) && value.allSatisfy { $0.isASCII && $0.isNumber }
    }
}

/// Recipe metadata persisted with local Jobs. Ordinary distributed recipes never carry this field.
public struct LocalExperimentalRecipeMetadata: Codable, Sendable, Equatable {
    public var appID: String
    public var target: String
    public var recipeID: String
    public var package: String
    public var versionCode: Int
    public var apkSize: Int64
    public var architectures: [String]
    public var appIDProvenance: String
    public var apkSHA256: String
    public var engine: LocalGenericEngine
    public var entrypoint: String
    public var nativeLibraries: [String]
    public var toolchain: String
    public var decisions169: LocalRecipeAnalysis169? = nil
    public var associatedFiles: [LocalProvisionalRecipe.ExternalFile]

    public init(target: LocalExperimentalTarget, apkSHA256: String,
                associatedFiles: [LocalProvisionalRecipe.ExternalFile], package: String,
                versionCode: Int, apkSize: Int64, architectures: [String], recipeID: String) {
        appID = target.appID
        self.target = target.target
        self.recipeID = recipeID
        self.package = package
        self.versionCode = versionCode
        self.apkSize = apkSize
        self.architectures = architectures.sorted()
        appIDProvenance = target.provenance
        self.apkSHA256 = apkSHA256.lowercased()
        engine = target.engine
        entrypoint = target.entrypoint
        nativeLibraries = target.nativeLibraries
        toolchain = target.toolchain
        self.associatedFiles = associatedFiles
    }

    public var isValid: Bool {
        apkSHA256.count == 64 && apkSHA256.allSatisfy(\.isHexDigit)
            && !appIDProvenance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && ExperimentalRuntime183(rawValue: toolchain) != nil
            && LocalExperimentalTarget.isValidAppID(appID)
            && target == "x\(appID)"
            && Recipe.isSafeName(recipeID)
            && Recipe.isSafeName(package)
            && versionCode > 0
            && apkSize > 0
            && architectures.contains("arm64-v8a")
            && Recipe.isSafeName(entrypoint)
            && nativeLibraries.allSatisfy(Recipe.isSafeRelativePath)
            && associatedFiles.allSatisfy(\.isSafeForExperimentalRecipe)
    }
}

public extension LocalProvisionalRecipe.ExternalFile {
    var fileName: String { URL(fileURLWithPath: path).lastPathComponent }
    var isSafeForExperimentalRecipe: Bool {
        guard path.hasPrefix("/"), URL(fileURLWithPath: path).standardizedFileURL.path == path,
              Recipe.isSafeName(fileName), size > 0,
              let sha256, sha256.count == 64, sha256.allSatisfy(\.isHexDigit),
              let destination, Recipe.isSafeRelativePath(destination),
              let kind, ["obb", "asset", "other"].contains(kind),
              let package, Recipe.isSafeName(package),
              let versionCode, Int(versionCode) != nil,
              let mappingEvidence, !mappingEvidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              validationStatus == "sha256-verified" else { return false }
        if kind == "obb" { return fileName.lowercased().hasSuffix(".obb") }
        return true
    }
}
