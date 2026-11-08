import Foundation

/// Persistent state follows the app identity: the official app uses `AVPPlay`, the modified app `AVPPlayModificado`.
public enum DataLocation {
    public static let originalBundleIdentifier = "io.github.mymartek.avpplay"
    public static let modifiedBundleIdentifier = "io.github.mymartek.avpplay.modified"
    public static let candidateBundleIdentifier = "io.github.mymartek.avpplay.modified.candidate187"
    public static func isCandidate(bundleIdentifier: String?) -> Bool { bundleIdentifier == candidateBundleIdentifier }
    /// The bundled CLI may have no Bundle.main identifier. Both entry points use the
    /// parent app's explicit domain rather than a shared helper executable name.
    public static func preferencesDomain(bundleIdentifier: String?) -> String? {
        isCandidate(bundleIdentifier: bundleIdentifier) ? candidateBundleIdentifier + ".preferences" : nil
    }
    public static var preferences: UserDefaults {
        guard let domain = preferencesDomain(bundleIdentifier: runningBundleIdentifier) else { return .standard }
        return UserDefaults(suiteName: domain)!
    }
    public static var isModified: Bool { isModified(bundleIdentifier: runningBundleIdentifier) }
    public static func isModified(bundleIdentifier: String?) -> Bool { bundleIdentifier == modifiedBundleIdentifier || isCandidate(bundleIdentifier: bundleIdentifier) }
    public static var folderName: String { folderName(bundleIdentifier: runningBundleIdentifier) }
    public static func folderName(bundleIdentifier: String?) -> String {
        if isCandidate(bundleIdentifier: bundleIdentifier) { return "AVPPlayCandidate187" }
        return isModified(bundleIdentifier: bundleIdentifier) ? "AVPPlayModificado" : "AVPPlay"
    }
    /// Der Ordner aus der Zeit vor dem Namen „AVP Play“.
    static let legacyFolderName = "QuestInstaller"

    public static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    public static func defaultBase(bundleIdentifier: String?, support: URL) -> URL {
        support.appendingPathComponent(folderName(bundleIdentifier: bundleIdentifier), isDirectory: true)
    }

    /// The candidate accepts a disjoint absolute override; the installed 179 keeps its existing behavior.
    /// The original/development build accepts `AVPPLAY_HOME` for disposable runs. The packaged modified app ignores
    /// it so a shell or launchd environment cannot redirect its persistent state into the official app's root.
    public static var base: URL {
        resolvedBase(bundleIdentifier: runningBundleIdentifier, support: applicationSupport,
                     homeOverride: ProcessInfo.processInfo.environment["AVPPLAY_HOME"])
    }

    /// Explicit namespace also covers hosts such as XCTest that ignore TMPDIR.
    public static var temporaryDirectory: URL {
        let identifier = runningBundleIdentifier
        let disposable = !isModified(bundleIdentifier: identifier)
            && ProcessInfo.processInfo.environment["AVPPLAY_HOME"]?.hasPrefix("/") == true
        let directory = resolvedTemporaryDirectory(bundleIdentifier: identifier, base: base,
                            system: FileManager.default.temporaryDirectory, disposable: disposable)
        if directory != FileManager.default.temporaryDirectory {
            // Fail closed: callers receive the candidate path even when creation fails.
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    static func resolvedTemporaryDirectory(bundleIdentifier: String?, base: URL, system: URL,
                                           disposable: Bool = false) -> URL {
        isCandidate(bundleIdentifier: bundleIdentifier) || disposable
            ? base.appendingPathComponent("tmp", isDirectory: true) : system
    }

    public static func resolvedBase(bundleIdentifier: String?, support: URL, homeOverride: String?) -> URL {
        if isCandidate(bundleIdentifier: bundleIdentifier), let homeOverride,
           homeOverride.hasPrefix("/"), isIsolated(URL(fileURLWithPath: homeOverride), bundleIdentifier: bundleIdentifier) {
            return URL(fileURLWithPath: homeOverride, isDirectory: true).standardizedFileURL
        }
        if !isModified(bundleIdentifier: bundleIdentifier), let homeOverride, homeOverride.hasPrefix("/") {
            return URL(fileURLWithPath: homeOverride, isDirectory: true).standardizedFileURL
        }
        let fallback = defaultBase(bundleIdentifier: bundleIdentifier, support: support)
        precondition(!isCandidate(bundleIdentifier: bundleIdentifier) || isIsolated(fallback, bundleIdentifier: bundleIdentifier),
                     "Candidate 187 data root overlaps protected data")
        return fallback
    }

    /// Resolve an override for mutable app data. A modified build refuses paths that alias or contain
    /// the official app's data root; an intentional external root remains supported.
    public static func directoryOverride(_ path: String?) -> URL? {
        directoryOverride(path, bundleIdentifier: runningBundleIdentifier)
    }

    public static func directoryOverride(_ path: String?, bundleIdentifier: String?) -> URL? {
        guard let path, path.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard isIsolated(url, bundleIdentifier: bundleIdentifier) else { return nil }
        return url
    }

    public static func isIsolated(_ url: URL, bundleIdentifier: String?) -> Bool {
        if isCandidate(bundleIdentifier: bundleIdentifier) {
            let protected = ["AVPPlay", "AVPPlayModificado", "AVPPlayCandidate", "AVPPlayCandidate185", "AVPPlayCandidate186", legacyFolderName].map {
                applicationSupport.appendingPathComponent($0, isDirectory: true)
            }
            let appRoots = [
                FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/AVP Play Candidate 185.app"),
                FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/AVP Play Candidate 186.app"),
                FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/AVP Play Modificado"),
                URL(fileURLWithPath: "/Applications/AVP Play.app")
            ]
            guard let path = canonicalCandidatePath(url) else { return false }
            return !(protected + appRoots).contains {
                guard let other = canonicalCandidatePath($0) else { return true }
                return path == other || path.hasPrefix(other + "/") || other.hasPrefix(path == "/" ? "/" : path + "/")
            }
        }
        return !isModified(bundleIdentifier: bundleIdentifier) || !overlaps(url.standardizedFileURL, standardOriginalBase)
    }

    // Resolve even dangling symlinks: Foundation's resolvingSymlinksInPath may leave
    // them unresolved when the protected destination does not exist yet.
    private static func canonicalCandidatePath(_ url: URL) -> String? {
        var pending = url.path.split(separator: "/").map(String.init)
        var parts: [String] = []
        var links = 0
        while !pending.isEmpty {
            let part = pending.removeFirst()
            if part == "." { continue }
            if part == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            let path = "/" + (parts + [part]).joined(separator: "/")
            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path) {
                links += 1
                guard links <= 40 else { return nil }
                if target.hasPrefix("/") { parts = [] }
                pending = target.split(separator: "/").map(String.init) + pending
            } else { parts.append(part) }
        }
        return "/" + parts.joined(separator: "/")
    }

    private static var standardOriginalBase: URL {
        applicationSupport.appendingPathComponent("AVPPlay", isDirectory: true).standardizedFileURL
    }

    private static func overlaps(_ a: URL, _ b: URL) -> Bool {
        let ap = a.resolvingSymlinksInPath().standardizedFileURL.path
        let bp = b.resolvingSymlinksInPath().standardizedFileURL.path
        return ap == bp || ap.hasPrefix(bp + "/") || bp.hasPrefix(ap + "/")
    }

    /// The bundled CLI lives below the .app bundle, so its own Bundle.main may not have an identifier.
    /// Walk upward from argv[0] to retain the parent app's data namespace.
    public static var runningBundleIdentifier: String? {
        if let identifier = Bundle.main.bundleIdentifier { return identifier }
        guard let bundleURL = runningAppBundleURL else { return nil }
        return Bundle(url: bundleURL)?.bundleIdentifier
    }

    public static var runningAppBundleURL: URL? {
        if Bundle.main.bundleURL.pathExtension == "app" { return Bundle.main.bundleURL }
        guard let argument = CommandLine.arguments.first else { return nil }
        var candidate = URL(fileURLWithPath: argument).resolvingSymlinksInPath().standardizedFileURL
        for _ in 0..<8 {
            if candidate.pathExtension == "app", Bundle(url: candidate)?.bundleIdentifier != nil { return candidate }
            candidate.deleteLastPathComponent()
        }
        return nil
    }

    /// Copy only local-library preferences into the new domain once. Account, catalog and credential settings
    /// are deliberately excluded; Keychain items are never read or migrated here.
    public static func migrateLocalLibraryPreferencesIfNeeded(target: UserDefaults = DataLocation.preferences,
                                                               source: UserDefaults? = nil,
                                                               modified: Bool? = nil,
                                                               bundleIdentifier: String? = runningBundleIdentifier) {
        guard !isCandidate(bundleIdentifier: bundleIdentifier) else { return }
        guard modified ?? isModified else { return }
        let marker = "avpplayModifiedLocalLibraryPreferencesMigrated"
        guard !target.bool(forKey: marker),
              let source = source ?? UserDefaults(suiteName: originalBundleIdentifier) else { return }
        for key in ["localRecipeFilters", "localRecipeFilterModes", "localRecipeID"] {
            if let value = source.object(forKey: key), target.object(forKey: key) == nil {
                target.set(value, forKey: key)
            }
        }
        target.set(true, forKey: marker)
    }

    /// Übernimmt einmalig die Daten aus dem früheren Ordner, indem er umbenannt wird – nichts wird kopiert
    /// oder gelöscht. Gibt es den neuen Ordner schon, bleibt alles, wie es ist.
    /// - Returns: ob umbenannt wurde.
    @discardableResult
    public static func adoptLegacyData(in support: URL = applicationSupport) -> Bool {
        guard !isModified else { return false }
        let fm = FileManager.default
        let old = support.appendingPathComponent(legacyFolderName, isDirectory: true)
        let new = support.appendingPathComponent(folderName, isDirectory: true)
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return false }
        return (try? fm.moveItem(at: old, to: new)) != nil
    }
}
