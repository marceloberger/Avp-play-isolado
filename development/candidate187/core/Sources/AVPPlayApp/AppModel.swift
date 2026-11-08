import AppKit
import AVPPlayCore
import Combine
import Network
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

/// Ein Spiel in der Übersicht: sein Rezept, sein Stand und sein Titelbild.
struct Game: Identifiable {
    let recipe: Recipe
    var status: GameStatus
    var cover: NSImage?
    /// Was das Spiel auf diesem Mac belegt.
    var storeBytes: Int64 = 0
    /// Was der Online-Katalog über das Spiel sagt, soweit er es kennt.
    var catalog: CatalogGame?
    /// Kein mitgeliefertes Rezept, sondern ein Entwurf aus Katalog und Metas Werkzeug – oder erst ein Platzhalter.
    var draft = false
    /// Gesetzt, wenn statt einer geprüften Fassung eine ungetestete aus dem Store gewählt ist: der Name der Fassung,
    /// die ohne Wahl gilt.
    var testedVersion: String?
    /// Die Fassungen, zu denen das Projekt ein eigenes Rezept führt: zuerst die, die ohne Wahl gilt, dann weitere.
    /// Leer bei einem Spiel ohne mitgeliefertes Rezept.
    var verifiedVersions: [GameVersion] = []
    /// Die Kaufquellen, zwischen denen bei diesem Spiel gewählt werden kann – die des mitgelieferten Rezepts zuerst.
    /// Leer, wenn es nur eine gibt.
    var sources: [Recipe.Source] = []
    /// Die Versionscodes, unter denen dasselbe Spiel aus einer anderen Kaufquelle installiert wäre.
    var otherSourceBuilds: [Int] = []
    /// Ein Versuch, dessen APK sich als 2D-App herausgestellt hat (`FlatApp`), kein VR-Spiel.
    var flatApp = false
    var id: String { recipe.id }
    /// Sind die Dateien des Spiels bekannt? Bei einem Platzhalter noch nicht.
    var prepared: Bool { !draft || !recipe.files.isEmpty }
    /// Mixed-Reality-Modus, der hier funktioniert: sagt das Rezept oder der Katalog.
    var mixedReality: Bool { recipe.mixedReality == true || catalog?.mixedReality == true }
    /// Wie weit dem Spiel zu trauen ist. Was der Katalog sagt, gilt – dort legt das Projekt fest oder zählen die
    /// Meldungen. Ohne Katalog (kein Netz, abgeschaltet, Sonderapp) gilt das mitgelieferte Rezept.
    var trust: Trust {
        // An aggregate catalog report cannot promote a local experimental recipe.
        if (recipe.id.hasPrefix("local-") || recipe.localExperimental != nil
            || recipe.files.contains(where: { $0.id == "local-community" })), recipe.status.playability == "untested",
           catalog?.status != "incompatible" { return .untested }
        // Geprüft ist eine Fassung, nicht ein Name: die neuere aus dem Store hat das Projekt nicht gesehen.
        if testedVersion != nil { return .untested }
        // Ebenso eine Kaufquelle: Was der Katalog sagt, gilt der Fassung aus dem Meta-Store. Die aus Steam ist ein
        // anderer Stand des Spiels und trägt ihr eigenes Urteil im Rezept.
        if recipe.source == .steam, !sources.isEmpty, recipe.status.playability != "verified" { return .untested }
        switch catalog?.status {
        case "verified": return .verified
        case "community": return .community
        case "incompatible": return .incompatible
        case "untested": return .untested
        default: return !draft && recipe.status.playability == "verified" ? .verified : .untested
        }
    }
    var incompatible: Bool { trust == .incompatible }
    /// Sonderapps kommen nicht aus dem Meta-Store; für sie wird kein Meta-Konto gebraucht.
    var needsMetaAccount: Bool { recipe.store.appId != nil }
    /// Aus dem eigenen Steam-Kauf: Besitz und Zusatzinhalte bestätigt Steam, geladen wird mit Valves Werkzeug.
    var needsSteamAccount: Bool { recipe.source == .steam }
    /// Kommt das Spiel aus einem Store, bei dem das Programm den Kauf prüft und die Dateien selbst lädt?
    var fromStore: Bool { recipe.source != nil }
    /// Vom Projekt selbst auf einer Vision Pro geprüft.
    var verified: Bool { trust == .verified }
    var installed: Bool {
        switch status.onDevice {
        case .current, .olderToolchain, .olderGame, .unstamped: return true
        // Was aus der anderen Kaufquelle auf dem Gerät liegt, ist nicht diese Installation.
        case .notInstalled, .unknown, .otherSource: return false
        }
    }
    /// Liegt dasselbe Spiel aus der anderen Kaufquelle auf dem Gerät?
    var otherSourceInstalled: Bool {
        if case .otherSource = status.onDevice { return true }
        return false
    }
    /// Liegt alles, woraus das Spiel gebaut wird, vollständig auf diesem Mac?
    var downloaded: Bool { prepared && status.filesRequired + status.treesRequired > 0 && status.stockComplete }
}

/// Die letzten Zeilen eines Verlaufs (höchstens `AppModel.logLinesKept` und ein Schub) und wie viele es insgesamt sind.
struct LogTail: Equatable {
    var lines: [String] = []
    var total = 0
}

struct UnconfirmedLocalInstallation: Identifiable, Sendable {
    let signing: SigningRecord
    var id: String {
        "\(signing.localAPKVariantID ?? ""):\(signing.installedConfiguration?.device ?? ""):\(signing.bundleId ?? ""):\(signing.installed.timeIntervalSince1970)"
    }
}

/// Vom Projekt geprüft, von Nutzern bestätigt, noch offen, oder von Nutzern als nicht lauffähig gemeldet.
enum Trust: Int { case verified, community, untested, incompatible }

/// Gehört das Spiel dem angemeldeten Konto? Sonderapps haben keinen Store-Titel; bei ihnen stellt sich die Frage nicht.
enum Owned { case notApplicable, unknown, yes, no }

/// Was der Nutzer für ein Spiel zusätzlich gewählt hat.
struct GameOptions: Codable, Equatable {
    /// Sprachen, deren wählbare Dateien mitkommen (Kürzel wie im Rezept).
    var locales: [String] = []
    /// Weitere wählbare Dateien, mit Namen.
    var optionalNames: [String] = []
    /// Gekaufte Zusatzinhalte laden und freischalten.
    var addons = true
    /// Beim Installieren die Spielstände vom Mac zurückspielen, wenn das Spiel auf dem Gerät noch keine hat.
    /// Wählbar und nicht fest, weil ältere gespeicherte Angaben den Eintrag nicht kennen; ohne Angabe: ja.
    var restoreSaves: Bool?
    /// Test: die XR-Vorhersage in diesem Spiel von Anfang an einschalten (`Toolchain.xrPredictionSwitch`). Ohne
    /// Angabe: aus – das Spiel bekommt die Kopfpose ohne Vorhersage.
    var xrPrediction: Bool?
    var coreMods: Bool?
    /// nil inherits the general build setting; explicit values apply only to this game's next Jobs.
    var frameGeneration: FrameGeneration?
    var controllerMode: ControllerMode?
    var surrealSupport: Bool?
    var surrealSDK: SurrealSDKPolicy?
}

/// Die in der Übersicht angehakten Spiele – ein eigener, kleiner Zustand (siehe `AppModel.picked`).
@MainActor
final class GameSelection: ObservableObject {
    @Published var ids: Set<String> = []
}

enum AccountState: Equatable {
    case unknown, checking, signedOut, signedIn
    /// Ein Token liegt im Schlüsselbund, Meta nimmt ihn aber nicht (mehr) an – oder ist nicht erreichbar.
    case problem(String)
}

enum AppSection: String, CaseIterable, Identifiable {
    /// Die Einstellungen stehen als letzter Punkt in der Seitenleiste, nicht in einem eigenen Fenster.
    case library, games, filters, localLibrary, appleMusic, jobs, data, setup, remote, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .library: return "Minha biblioteca"
        case .filters: return L("Filters", "Filter")
        case .games: return L("Games", "Spiele")
        case .localLibrary: return L("Local Library", "Lokale Bibliothek")
        case .appleMusic: return "Apple Music Search"
        case .jobs: return L("Jobs", "Aufträge")
        case .data: return L("Data", "Datenverwaltung")
        case .setup: return L("Setup", "Einrichtung")
        case .remote: return "Remote Control"
        case .settings: return L("Settings", "Einstellungen")
        }
    }
    var symbol: String {
        switch self {
        case .library: return "square.grid.2x2.fill"
        case .filters: return "line.3.horizontal.decrease.circle"
        case .games: return "square.grid.2x2"
        case .localLibrary: return "externaldrive.badge.plus"
        case .appleMusic: return "music.note"
        case .jobs: return "list.bullet.clipboard"
        case .data: return "externaldrive"
        case .setup: return "checklist"
        case .remote: return "visionpro"
        case .settings: return "gearshape"
        }
    }
}

/// Der Zustand der Oberfläche. Alles, was länger dauert (Gerät fragen, laden, bauen), läuft außerhalb des
/// Hauptfadens; hier landen nur die Ergebnisse.
@MainActor
final class AppModel: ObservableObject {
    @Published var section: AppSection = .library
    @Published var localRecipes: [Recipe] = []
    @Published var localProvisionalRecipes: [LocalProvisionalRecipe] = []
    @Published var localRecipeLoadError: String?
    @AppStorage("localRecipeID") var selectedLocalRecipeID = ""
    @AppStorage("localRecipeSelectionExplicit") var localRecipeSelectionExplicit = false
    @Published var localCommunitySelectionChoices: [LocalCommunitySelectionChoice] = []
    @Published var localCommunitySelectionMessage: String?
    @Published var localRecipeFilters: [LocalRecipeFilter] = LocalRecipeFilters.decode(DataLocation.preferences.data(forKey: "localRecipeFilters")) {
        didSet { DataLocation.preferences.set(LocalRecipeFilters.encode(localRecipeFilters), forKey: "localRecipeFilters") }
    }
    @Published var localRecipeFilterModes: [String: LocalRecipeFilterMode] = LocalRecipeFilters.decodeModes(
        DataLocation.preferences.data(forKey: "localRecipeFilterModes"),
        filters: LocalRecipeFilters.decode(DataLocation.preferences.data(forKey: "localRecipeFilters"))) {
        didSet { DataLocation.preferences.set(LocalRecipeFilters.encodeModes(localRecipeFilterModes), forKey: "localRecipeFilterModes") }
    }
    @Published var legacyFunctionalityCandidates: [String: LocalAPKInstallation] = [:]
    @Published var legacyFunctionalityProblems: [String: String] = [:]
    @Published var verifyingLegacyFunctionality: Set<String> = []
    @Published var localLibraryRevision = 0
    @Published var validatingLocalVariantIDs: Set<String> = []
    @Published var localValidationResults: [String: String] = [:]
    @Published var preparingLocalVariantIDs: Set<String> = []
    @AppStorage("localVariantDirectory") var localVariantDirectory = ""
    @AppStorage("localWorkspaceDirectory") var localWorkspaceDirectory = ""
    /// Das geöffnete Spiel in der Übersicht (leer: das Raster).
    @Published var gamePath: [String] = []
    @Published var games: [Game] = [] { didSet { if !replacingOne { rebuildAllGames() } } }
    /// Gesetzt, während ein einzelnes Spiel ersetzt wird (`replace`): Die Liste aller Spiele ist dann schon nachgeführt.
    var replacingOne = false
    @Published var loadProblem: String?
    @Published var device: Device?
    @Published var devices: [Device] = []
    /// Das gewählte Headset, wenn mehrere erreichbar sind; leer heißt: das einzige.
    @AppStorage("deviceUDID") var chosenDevice = ""
    @Published var deviceProblem: String?
    @Published var refreshing = false
    // MARK: Ohne Netz gestartet

    /// Bei der Anmeldung am Mac startet AVP Play oft, bevor das Netz steht (Neustart am 27.10.: „Meta nicht
    /// angemeldet“, obwohl der Zugang gültig war). Ein Verbindungsfehler ist kein Urteil über den Zugang: Die Prüfung
    /// läuft dann nach 3, 10, 30, 60 und 120 s noch einmal und zusätzlich, sobald macOS das Netz als verfügbar meldet.
    /// Der Katalog wird dabei mit nachgeladen.
    private var pathMonitor: NWPathMonitor?
    private var accountOffline = false
    private var offlineRetries = 0
    private static let offlineDelays: [Double] = [3, 10, 30, 60, 120]

    func startNetworkWatch() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in self?.retryAfterOffline() }
        }
        monitor.start(queue: DispatchQueue(label: "avpplay.network", qos: .utility))
        pathMonitor = monitor
    }

    private func retryAfterOffline() {
        if accountOffline { checkAccount() }
        if onlineCatalog, catalogProblem != nil { loadCatalog() }
    }

    func scheduleOfflineRetry() {
        guard offlineRetries < Self.offlineDelays.count else { return }
        let delay = Self.offlineDelays[offlineRetries]
        offlineRetries += 1
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            if self.accountOffline || self.catalogProblem != nil { self.retryAfterOffline() }
        }
    }
    @Published var toolchainText: String?
    @Published var account: AccountState = .unknown
    @Published var toolPresent = false
    @Published var xcodeText: String?
    @Published var xcodeProblem: String?
    @Published var jobs: [Job] = []
    @Published var selectedJob: String?
    @Published var runningJob: String?
    @Published var queued: [String] = []
    @Published var resumingJobIDs: Set<String> = []
    @Published var jobConnectionChecks: [String: JobConnectionCheckState] = [:]
    @Published var checkingConnectionJobID: String?
    let jobConnectionQuery: @Sendable (Job, ContentStore) throws -> String
    @Published var resumeMessages: [String: String] = [:]
    private let resumeDevices: @Sendable () throws -> [Device]
    @Published var logs: [String: LogTail] = [:]
    /// Die offenen Verlaufsdateien laufender Aufträge (siehe `closeLog`).
    private let logFiles = JobLogFiles()
    @Published var notice: String?
    @Published var importingLocalGameIDs: Set<String> = []
    @Published var localImport = LocalImportPresentation()
    @Published var localImportDiagnostic: String?
    @Published var localAdditionalReview: LocalAdditionalFileReview?
    @Published var localAdditionalReviewPreparing = false
    @Published var localAdditionalReviewError: String?
    @Published var localManualRecipeSelection = false
    @Published var localOperationMessages: [String: String] = [:]
    @Published var localAutomaticPlanning: Set<String> = []
    @Published var localOperationDiagnostics: [String: String] = [:]
    @Published var localOperationProgress: [String: LocalImportProgress] = [:]
    var localImportWorker: Task<LocalImportedGame, Error>?
    var provisionalWorker: Task<LocalProvisionalRecipe, Error>?
    var localImportToken: UUID?
    var localOperationWorkers: [String: Task<String, Error>] = [:]

    @Published var teamCandidates: [Probe.Team] = []
    /// Metas letzte Antworten auf die Besitzfrage, je Store-App.
    @Published var ownership: [String: OwnershipRecord] = [:]
    @Published var checkingOwnership = false
    @Published var horizonPlus: HorizonPlusCatalog? {
        didSet {
            horizonPlusIds = horizonPlus?.appIds ?? []
            horizonGamesIds = horizonPlus?.appIds(in: .games) ?? []
            horizonIndieIds = horizonPlus?.appIds(in: .indie) ?? []
        }
    }
    private(set) var horizonPlusIds: Set<String> = []
    private(set) var horizonGamesIds: Set<String> = []
    private(set) var horizonIndieIds: Set<String> = []
    @Published var loadingHorizonPlus = false
    @Published var horizonPlusProblem: String?
    var askedHorizonPlus: Set<String> = []

    /// Spiele, für die gerade einzeln bei Meta nachgefragt wird („Kauf prüfen“), und was dabei zuletzt zu sagen war.
    @Published var checkingPurchase: Set<String> = []
    @Published var purchaseNote: [String: String] = [:]
    /// Was zuletzt beim Einrichten von Metas Werkzeug herauskam – steht in der Karte „Meta-Konto“.
    @Published var toolNote: String?
    /// Der Dialog „Ein Problem melden“ ist offen; `reportJob` nennt den Auftrag, um den es geht.
    @Published var showReport = false
    @Published var reportJob: Job?
    @Published var lookingForTool = false
    private var toolWatch: Task<Void, Never>?
    @Published var freeBytes: Int64?
    /// Der Online-Katalog: was der Dienst des Projekts über weitere Spiele sagt.
    @Published var catalog: [CatalogGame] = [] { didSet { rebuildAllGames() } }
    /// Alle Spiele der Übersicht: die mit dem Programm gelieferten und schon nachgeschlagenen, ergänzt um das,
    /// was vom Katalog bisher geladen ist. Wird neu gebaut, wenn sich eine der beiden Seiten ändert.
    @Published var allGames: [Game] = []
    @Published var catalogProblem: String?
    /// Wie viele Spiele der Katalog insgesamt kennt, und ob nach den geladenen Seiten noch welche kommen.
    @Published var catalogTotal: Int?
    @Published var catalogMore = false
    @Published var loadingMore = false
    var catalogNextPage = 0
    /// Nach welchen eigenen Spielen der Katalog schon gezielt gefragt wurde.
    var askedOwn: Set<String> = []
    /// Dasselbe für die laufende Suche.
    @Published var searchedQuery = ""
    @Published var searchMore = false
    var searchNextPage = 0
    @AppStorage("filterCommunity") var filterCommunity = false
    /// Steam: der Kontoname (kein Geheimnis; Passwort und Code sieht dieses Programm nie), ob Valves Werkzeug da
    /// ist und für welches Konto die Anmeldung zuletzt gelang.
    @AppStorage("steamAccount") var steamAccount = ""
    @AppStorage("steamSignedInAs") var steamSignedInAs = ""
    @Published var steamToolPresent = SteamTool().isInstalled
    @Published var steamSettingUp = false
    /// Valves Werkzeug liegt als Intel-Programm da, und dem Mac fehlt Rosetta.
    @Published var steamNeedsRosetta = SteamTool().needsRosetta()
    @Published var rosettaInstalling = false
    @Published var steamNote: String?
    @Published var steamLibrary: SteamLibrary? { didSet { rebuildAllGames() } }
    @Published var loadingSteamLibrary = false
    @Published var steamLibraryProblem: String?
    var steamLibraryAccount: String?
    var steamLibraryGeneration = UUID()

    /// Je Spiel: läuft gerade ein Abruf bei Steam, wie weit ist er, und was hat er zuletzt gesagt.
    @Published var steamBusy: Set<String> = []
    @Published var steamProgress: [String: SteamProgress] = [:]
    @Published var steamSaid: [String: String] = [:]
    let steamStops = StopFlags()
    @Published var searchText = ""
    @Published var searching = false
    @Published var preparing: Set<String> = []
    @Published var prepareNote: [String: String] = [:]
    @Published var favourites: Set<String> = Set(DataLocation.preferences.stringArray(forKey: "favourites") ?? [])
    @Published var customFilters: [CustomFilter] = CustomFilters.decode(DataLocation.preferences.string(forKey: "customFilters")) {
        didSet { DataLocation.preferences.set(CustomFilters.encode(customFilters), forKey: "customFilters") }
    }
    @Published var customFilterModes: [String: CustomFilterMode] = CustomFilters.modes(
        from: DataLocation.preferences.dictionary(forKey: "customFilterModes") as? [String: String],
        filters: CustomFilters.decode(DataLocation.preferences.string(forKey: "customFilters"))) {
        didSet { DataLocation.preferences.set(customFilterModes.mapValues(\.rawValue), forKey: "customFilterModes") }
    }
    @Published var sentFeedback: [String: String] = DataLocation.preferences.dictionary(forKey: "sentFeedback") as? [String: String] ?? [:]
    // Matches AVP Play 1.8.0. Disabling the online extension still leaves the shipped recipe catalogue visible.
    @AppStorage("onlineCatalog") var onlineCatalog = true
    /// Dem Katalog sagen, dass die App in Gebrauch ist und welche Spiele installiert wurden – ohne Kennung.
    @AppStorage("shareFingerprints") var shareFingerprints = false
    @AppStorage("usageCounts") var usageCounts = false
    /// Titelbilder für Spiele, die noch nicht geladen sind, von deren öffentlicher Store-Seite holen.
    @AppStorage("storePictures") var storePictures = false
    /// Der aktuelle Build geprüfter Store-Spiele, wie der Katalog ihn kennt (Kennung des Rezepts → Build).
    @Published var storeBuilds: [String: CatalogBuild] = [:]
    /// Alle Fassungen, die der Store zu einem Spiel des Kontos nennt, die neueste zuerst (Kennung des Rezepts →
    /// Builds). Nur wo Meta selbst gefragt wurde; sonst kennt die App nur den einen Build des Katalogs.
    @Published var storeBuildLists: [String: [CatalogBuild]] = [:]
    /// Für welche Spiele die neueste Fassung aus dem Store statt der geprüften gewählt ist.
    @Published var latestChoices = StoreUpdate.Choices.load()
    /// Ältere Toolchains von selbst entfernen, sobald eine neuere installiert ist und nichts mehr mit ihnen baut.
    @AppStorage("autoRemoveOldToolchains") var autoRemoveOldToolchains = true
    /// Initial controller mode for newly built games; the headset preference wins later.
    @AppStorage(RuntimeBuildPreferences.controllerModeKey) var controllerMode: ControllerMode = .standard
    @AppStorage(RuntimeBuildPreferences.surrealSupportKey) var surrealSupport = true
    @AppStorage(RuntimeBuildPreferences.frameGenerationKey) var defaultFrameGeneration: FrameGeneration = .automatic
    @AppStorage(RuntimeBuildPreferences.surrealSDKKey) var defaultSurrealSDK: SurrealSDKPolicy = .verified
    var runtimeBuildPreferences: RuntimeBuildPreferences {
        RuntimeBuildPreferences(surrealSupport: surrealSupport, controllerMode: controllerMode,
                                frameGeneration: defaultFrameGeneration, surrealSDK: defaultSurrealSDK)
    }
    /// Experimentell: In jedem Spiel, das installiert oder aktualisiert wird, ist die neue Audio-Implementierung der
    /// Toolchain von Anfang an eingeschaltet (`Toolchain.experimentalSwitches`) – als wäre die bisherige schon
    /// entfernt. Die Kopfposen-Implementierung, die die Liste auch nennt, wirkt nur noch mit Toolchain 507; neuere
    /// benutzen sie ohnehin (Klepton #9). Ein Bau, der es anders hält als diese Einstellung, gilt als
    /// aktualisierbar, sodass „Alle aktualisieren“ nach dem Umlegen alle installierten Spiele umstellt.
    @AppStorage(AppModel.experimentalKey) var experimentalImplementations = false
    nonisolated static let experimentalKey = "experimentalImplementations"
    /// Was `GameStatus` von einem aktuellen Bau erwartet: die Einstellung, wo die neueste Toolchain sie umsetzen
    /// kann. Liest die Einstellung selbst, weil die Bestandsaufnahme nicht auf dem Hauptthread läuft.
    nonisolated static func experimentalExpected(toolchain: Toolchain?) -> Bool? {
        guard let toolchain, toolchain.supportsExperimental else { return nil }
        return DataLocation.preferences.bool(forKey: experimentalKey)
    }
    /// MetalFX: In jedem Spiel, das installiert oder aktualisiert wird, ist das Hochskalieren des Compositors von
    /// Anfang an eingeschaltet (`Toolchain.metalFXSwitch`, Klepton PR #2). Aus ist das bisherige Verhalten: Das Spiel
    /// startet mit dem linearen Strecken, und der Schalter im Spiel entscheidet. Wie bei der experimentellen
    /// Einstellung gilt ein Bau, der es anders hält, als aktualisierbar.
    @AppStorage(AppModel.metalFXKey) var metalFXUpscaling = false
    nonisolated static let metalFXKey = "metalFXUpscaling"
    /// Die Auflösung in Prozent, mit der ein Spiel bei eingeschaltetem MetalFX beginnt (`MetalFXResolution`).
    @AppStorage("metalFXResolution") var metalFXResolution = MetalFXResolution.full
    /// Der Wert von vor dem Einschalten; 0: keiner.
    @AppStorage("metalFXResolutionBefore") private var metalFXResolutionBefore = 0
    /// Den MetalFX-Schalter umlegen: Ein belegt die Auflösung mit 75 % vor, aus stellt die von davor wieder her.
    func setMetalFXUpscaling(_ on: Bool) {
        let state = MetalFXResolution.switched(metalFX: on, was: metalFXUpscaling,
                                               state: .init(resolution: metalFXResolution,
                                                            before: metalFXResolutionBefore > 0 ? metalFXResolutionBefore : nil))
        metalFXResolution = state.resolution
        metalFXResolutionBefore = state.before ?? 0
        metalFXUpscaling = on
    }
    /// Was `GameStatus` von einem aktuellen Bau zum MetalFX-Hochskalieren erwartet; `nil` ohne eine Toolchain, die es
    /// kann.
    nonisolated static func metalFXExpected(toolchain: Toolchain?) -> Bool? {
        guard let toolchain, toolchain.supportsMetalFX else { return nil }
        return DataLocation.preferences.bool(forKey: metalFXKey)
    }
    /// Was `GameStatus` von einem aktuellen Bau zur XR-Vorhersage erwartet – je Spiel, aus dessen Option
    /// (`GameOptions.xrPrediction`); `nil` ohne eine Toolchain, die sie umstellen kann. Liest die gespeicherten
    /// Optionen selbst, weil die Bestandsaufnahme nicht auf dem Hauptthread läuft.
    nonisolated static func xrPredictionExpected(supported: Bool?) -> ((String) -> Bool)? {
        guard supported == true else { return nil }
        let saved = DataLocation.preferences.data(forKey: "gameOptions")
            .flatMap { try? JSONDecoder().decode([String: GameOptions].self, from: $0) } ?? [:]
        let on = Set(saved.filter { $0.value.xrPrediction == true }.keys)
        return { on.contains($0) }
    }
    /// Für welche Spiele eine andere Toolchain als die neueste gewählt ist (siehe `ToolchainChoices`).
    @Published var toolchainChoices = ToolchainChoices.load()
    /// Die Pakete früherer Veröffentlichungen auf GitHub; `nil`, solange niemand danach gefragt hat.
    @Published var releasedToolchains: [ReleasedToolchain]?
    @Published var releasedToolchainsLoading = false
    /// Je Spiel die Nummer des Pakets, das gerade für es geladen wird.
    @Published var toolchainArriving: [String: ReleasedToolchain] = [:]
    @Published var toolchainNote: [String: String] = [:]
    /// Besorgt diese Bilder: zwei Abrufe zugleich, mit Zwischenspeicher.
    let covers = CoverLoader()
    @AppStorage("filterFavourites") var filterFavourites = false
    /// Was das Gerät zuletzt als installiert gemeldet hat, und ab welcher Toolchain-Nummer ein Bau aktuell ist.
    /// Nicht `@Published`, fließt aber in `derived` ein – daher verwirft jede Änderung es selbst.
    var installedApps: [InstalledApp]? { didSet { invalidateDerived() } }
    var toolchainRevision: Int? { didSet { invalidateDerived() } }
    /// Was ein aktueller Bau von der experimentellen Einstellung tragen soll; `nil`, solange keine Toolchain da
    /// ist, die das kann – dann wird nicht verglichen.
    var experimentalExpected: Bool? { didSet { invalidateDerived() } }
    /// Dasselbe für das MetalFX-Hochskalieren.
    var metalFXExpected: Bool? { didSet { invalidateDerived() } }
    /// Ob die neueste Toolchain die XR-Vorhersage als Option kennt; `nil` ohne Toolchain.
    @Published var xrPredictionSupported: Bool?
    /// Initial play-area default shared with the CLI, scoped to this app's data root.
    @Published var roomMeasuringForNewGames = InstallDefaults.roomMeasuring() {
        didSet {
            guard roomMeasuringForNewGames != oldValue else { return }
            try? InstallDefaults.setRoomMeasuring(roomMeasuringForNewGames)
        }
    }
    /// Die Sprache, mit der Spiele beim Installieren oder Neubauen beginnen (`InstallDefaults.gameLanguage`; leer:
    /// keine Vorgabe). In derselben Datei wie die Raumvermessung, aus demselben Grund.
    @Published var gameLanguageForNewGames = InstallDefaults.gameLanguage() ?? "" {
        didSet {
            guard gameLanguageForNewGames != oldValue else { return }
            try? InstallDefaults.setGameLanguage(gameLanguageForNewGames.isEmpty ? nil : gameLanguageForNewGames)
        }
    }
    /// Current file download or device copy progress for each running job.
    @Published var copyProgress: [String: InstallProgress] = [:]
    /// Eine neuere veröffentlichte Fassung, falls es eine gibt.
    @Published var availableFingerprints: [String: Fingerprint] = [:]
    @Published var prognoses: [String: Prognosis] = [:]
    @Published var prognosisRunning: Set<String> = []
    /// Die Namen, die eine Toolchain kennt, je Ordner der Toolchain – einmal gelesen.
    var runtimeInterfaces: [String: RuntimeInterface] = [:]
    @Published var update: AppRelease?
    @Published var updateState: UpdateState = .idle
    @AppStorage("autoUpdateCheck") var autoUpdateCheck = false
    @AppStorage("lastUpdateCheck") var lastUpdateCheck: Double = 0
    /// Das Entwicklerteam, das dieses Programm signiert hat; `nil` bei einem Bau ohne Identität.
    let ownTeam: String? = Bundle.main.bundleIdentifier == nil ? nil : Updater.team(of: Bundle.main.bundleURL)
    private var awake: NSObjectProtocol?
    @Published private var options: [String: GameOptions] = [:]
    /// Die Filter der Übersicht; mehrere zugleich engen weiter ein.
    @AppStorage("filterVerified") var filterVerified = false
    @AppStorage("filterInstalled") var filterInstalled = false
    /// Nur Spiele, deren Dateien vollständig auf dem Mac liegen, die aber nicht auf der Vision Pro sind.
    @AppStorage("filterDownloaded") var filterDownloaded = false
    /// Nur gemerkte Spiele, deren Dateien noch nicht vollständig auf dem Mac liegen: was von den Favoriten noch zu
    /// laden ist. Das Gegenstück zu „Geladen, nicht installiert“ eine Stufe früher.
    @AppStorage("filterFavouritesMissing") var filterFavouritesMissing = false
    /// Nur Spiele mit einem Mixed-Reality-Modus, der mit AVP Play funktioniert.
    @AppStorage("filterMixedReality") var filterMixedReality = false
    @AppStorage("filterHorizonGames") var filterHorizonGames = false
    @AppStorage("filterHorizonIndie") var filterHorizonIndie = false
    var horizonPlusWanted: Bool { filterHorizonGames || filterHorizonIndie }
    var customOnlyWanted: Bool { customFilterModes.values.contains(.only) }
    func inChosenHorizonPlus(_ game: Game) -> Bool {
        guard let app = game.recipe.catalogAppId else { return false }
        return (filterHorizonGames && horizonGamesIds.contains(app)) || (filterHorizonIndie && horizonIndieIds.contains(app))
    }


    /// Ob ein Filter gesetzt ist, der die Favoriten braucht – dann sollen alle dastehen, auch die, bis zu denen der
    /// Katalog noch nicht geladen ist.
    var favouritesWanted: Bool { filterFavourites || filterFavouritesMissing }
    private var routed = false
    @AppStorage("teamId") var teamId = ""
    /// Die Sprache, in der das Programm gerade spricht. Ansichten hängen daran und bauen sich beim Wechsel neu.
    @Published private(set) var language: Language = .en
    @AppStorage("language") private var languageRaw = LanguageChoice.system.rawValue
    /// Vom Nutzer gesetztes Präfix der App-Kennungen; leer heißt Standard.
    @AppStorage("bundlePrefix") var customBundlePrefix = ""

    /// Vor allem anderen: Daten aus der Zeit vor dem Namen „AVP Play“ übernehmen (der Ordner wird umbenannt).
    /// Neu gesetzt wird das nur, wenn der Ordner für Downloads gewechselt hat (siehe `moveStore`).
    @Published var paths: Paths
    /// Dependency injection for offline UI/admission tests; production always runs the worker.
    private let runJobsAutomatically: Bool
    var localVariantStore: LocalAPKVariantStore {
        let root = DataLocation.directoryOverride(localVariantDirectory)
            ?? DataLocation.base.appendingPathComponent("local-variants", isDirectory: true)
        return LocalAPKVariantStore(root: root)
    }
    var localWorkspaceRoot: URL {
        DataLocation.directoryOverride(localWorkspaceDirectory)
            ?? DataLocation.base.appendingPathComponent("build-only", isDirectory: true)
    }
    /// Die Datenverwaltung: was auf dem Mac liegt, und ein laufender Umzug des Ordners für Downloads.
    @Published var storage: StorageOverview?
    @Published var storageScanning = false
    @Published var storeMove: StoreMove.Progress?
    @Published var storeMoveNote: String?
    let storeMoveStop = StopFlags()
    private var runningTask: Task<Void, Never>?
    private var stopRequested: Set<String> = []
    @Published var localCancellingJobs: Set<String> = []
    /// Die in der Übersicht angehakten Spiele, und ob gerade ein Sammelauftrag für sie vorbereitet wird.
    /// Nicht `@Published`: Hinge die Auswahl am Zustand der ganzen Oberfläche, würde jeder Haken die Übersicht neu
    /// filtern, sortieren und jede schon gezeichnete Karte samt Bild neu aufbauen – bei vielen geladenen Spielen
    /// spürbar träge. So hören nur die Haken, die Rahmen und die Leiste auf sie.
    let picked = GameSelection()
    var selection: Set<String> {
        get { picked.ids }
        set { picked.ids = newValue }
    }
    @Published var bulkBusy = false
    /// Der Hintergrunddienst, der ablaufende Signaturen erneuert: ob er eingetragen sein soll, in welchem Abstand
    /// er prüft, und was der letzte Lauf ergab.
    @AppStorage("renewInBackground") var renewInBackground = false
    @AppStorage("renewIntervalHours") var renewIntervalHours = BackgroundService.defaultInterval
    @Published var renewalReport: RenewalReport? = RenewalReport.load()
    @Published var renewalNote: String?
    @Published var renewing = false
    /// Spielstände: ob sie von selbst von der Vision Pro geholt werden, wann zuletzt alle Spiele dran waren, der
    /// neueste Stand je Spiel (nach Kennung des Rezepts), für welche Spiele gerade geholt oder zurückgespielt wird
    /// und was dabei zuletzt herauskam.
    @AppStorage("syncSaves") var syncSaves = true
    @AppStorage("lastSaveRound") var lastSaveRound: Double = 0
    @Published var saveSnapshots: [String: SaveSnapshot] = [:]
    @Published var savesBusy: Set<String> = []
    @Published var savesNote: [String: String] = [:]
    /// Welche Spiele bei der letzten Nachfrage auf dem Headset liefen – endet eines, werden seine Spielstände geholt.
    var runningGames: Set<String> = []
    var saveWatch: Task<Void, Never>?
    var saveTicks = 0

    /// Was aus dem übrigen Zustand folgt und teuer zu bestimmen ist, gemerkt bis zur nächsten Änderung: Jede
    /// Änderung an einer veröffentlichten Eigenschaft verwirft es, dieselbe, die die Oberfläche neu zeichnen lässt.
    /// Einstellungen (`@AppStorage`) melden sich dabei ebenso, auch wenn sie direkt in `UserDefaults` geändert
    /// werden. Was keine solche Meldung kennt, verwirft es selbst (`invalidateDerived`): die nicht veröffentlichten
    /// Angaben zum Gerät und zur Toolchain, und was sich außerhalb des Programms ändert – Toolchains, die die
    /// Kommandozeile installiert oder entfernt (beim Zurückkehren ins Programm), und ein- oder ausgehängte Platten.
    /// Nicht `@Published` – das Merken selbst ist keine Änderung.
    struct Derived {
        /// Doppelt optional: außen „noch nicht bestimmt“, innen „keine Toolchain“.
        var toolchain: Toolchain??
        var updatable: [Game]?
        var shownGames: [Game]?
    }
    var derived = Derived()
    private var derivedReset: AnyCancellable?
    private var derivedObservers: [NSObjectProtocol] = []

    init(paths: Paths? = nil, runJobsAutomatically: Bool = true,
         resumeDevices: @escaping @Sendable () throws -> [Device] = { try DeviceControl().devices() },
         jobConnectionQuery: @escaping @Sendable (Job, ContentStore) throws -> String = {
             try JobConnectionCheck.run(job: $0, store: $1)
         }) {
        if paths == nil { DataLocation.adoptLegacyData() }
        self.paths = paths ?? Paths()
        self.runJobsAutomatically = runJobsAutomatically
        self.resumeDevices = resumeDevices
        self.jobConnectionQuery = jobConnectionQuery
        applyLanguage()
        if let data = DataLocation.preferences.data(forKey: "gameOptions"),
           let saved = try? JSONDecoder().decode([String: GameOptions].self, from: data) { options = saved }
        derivedReset = objectWillChange.sink { [weak self] _ in
            MainActor.assumeIsolated { self?.invalidateDerived() }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for (center, name) in [(NotificationCenter.default, NSApplication.didBecomeActiveNotification),
                               (workspace, NSWorkspace.didMountNotification),
                               (workspace, NSWorkspace.didUnmountNotification),
                               (workspace, NSWorkspace.didRenameVolumeNotification)] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.invalidateDerived() }
            }
            derivedObservers.append(token)
        }
    }

    /// Verwirft, was in `derived` gemerkt ist; beim nächsten Fragen wird es neu bestimmt. Zeichnet nichts neu.
    func invalidateDerived() {
        derived = Derived()
    }

    // MARK: Besitz

    func owned(_ game: Game) -> Owned {
        guard let key = OwnershipCache.key(for: game.recipe) else { return .notApplicable }
        guard let record = ownership[key] else {
            if steamLibraryAccount == steamAccount, steamLibrary?.apps.contains(where: { "steam:" + $0.appId == key }) == true { return .yes }
            return .unknown
        }
        return record.owned ? .yes : .no
    }

    /// Das Rezept eines Spiels für eine Kaufquelle: das geltende, das mitgelieferte oder das aus `recipes/sources`.
    func recipe(of game: Game, source: Recipe.Source) -> Recipe? {
        if game.recipe.source == source { return game.recipe }
        guard !game.draft, let recipes = paths.recipes else { return nil }
        let store = RecipeStore(directory: recipes)
        if let shipped = try? store.load(id: game.id), shipped.source == source { return shipped }
        return store.loadSources().first { $0.id == game.id && $0.source == source }
    }

    /// Der Name einer Kaufquelle, wie er in Sätzen steht.
    static func name(_ source: Recipe.Source?) -> String { source == .steam ? "Steam" : "Meta" }

    /// Warum nichts geladen wird, wenn das Konto das Spiel nicht besitzt.
    func notOwnedText(_ game: Game) -> String {
        let store = AppModel.name(game.recipe.source)
        return L("This game is not in your \(store) account, so nothing is downloaded.",
                 "Dieses Spiel gehört nicht zu deinem \(store)-Konto. Es wird nichts geladen.")
    }

    /// Was fehlt, damit das Konto gefragt werden kann, bei dem das Spiel gekauft ist.
    func accountBlocker(for game: Game) -> String? {
        if game.needsSteamAccount, !steamSignedIn { return L("Sign in to Steam first (see “Setup”).", "Erst bei Steam anmelden (siehe „Einrichtung“).") }
        if game.needsMetaAccount, account != .signedIn { return L("For official Meta downloads, sign in under Settings → Official Meta downloads. The Local Library does not need this account.", "Für offizielle Meta-Downloads unter Einstellungen → Offizielle Meta-Downloads anmelden. Die lokale Bibliothek braucht dieses Konto nicht.") }
        return nil
    }

    /// Wählt, aus welchem Kauf ein Spiel geladen und installiert wird. Auf der Vision Pro ändert das nichts, bis
    /// installiert wird – und über die Fassung der anderen Quelle wird nicht installiert.
    func chooseSource(_ game: Game, _ source: Recipe.Source) {
        guard source != game.recipe.source, game.sources.contains(source) else { return }
        guard !isBusy(game.id), !steamBusy.contains(game.id) else {
            purchaseNote[game.id] = L("A job for this game is running. Switch the purchase source when it has finished.",
                                      "Für dieses Spiel läuft gerade ein Auftrag. Wechsle die Kaufquelle, wenn er fertig ist.")
            return
        }
        var choices = StoreUpdate.Choices.load()
        choices.choose(source: source, for: game.id, shipped: game.sources.first ?? .meta)
        try? choices.save()
        latestChoices = choices
        // Wer selbst gewählt hat, bei dem wird nicht mehr von selbst gewechselt.
        DataLocation.preferences.set(true, forKey: AppModel.sourceLookedKey(game.id))
        purchaseNote[game.id] = nil
        // Nur dieses Spiel wird neu bestimmt, mit dem, was über das Gerät schon bekannt ist. Alles neu zu laden
        // (Gerät fragen, jeden Ordner im Bestand zählen) dauert Sekunden und ändert an den anderen Spielen nichts.
        let id = game.id, catalog = game.catalog
        let paths = paths, apps = installedApps, revision = toolchainRevision, prefix = bundlePrefix, drafts = draftsDirectory
        let pin = toolchainChoices.games[id], experimental = experimentalExpected, metalFX = metalFXExpected
        let xrPrediction = xrPredictionExpected(for: id)
        Task.detached(priority: .userInitiated) {
            var fresh: Game?
            if let recipes = paths.recipes {
                let store = RecipeStore(directory: recipes)
                if let tested = try? store.load(id: id) {
                    let variants = store.loadVariants(), sources = store.loadSources()
                    let active = StoreUpdate.resolve([tested], variants: variants, sources: sources, drafts: drafts, choices: choices).first ?? tested
                    fresh = Probe.game(active, draft: false, tested: tested, variants: variants, sources: sources, paths: paths,
                                       apps: apps, toolchainRevision: revision, pin: pin, bundlePrefix: prefix,
                                       experimental: experimental, metalFX: metalFX, xrPrediction: xrPrediction)
                    fresh?.catalog = catalog
                }
            }
            let result = fresh
            await MainActor.run {
                guard let result else { self.refresh(); return }
                self.replace(result)
                // Für die neue Quelle steht der Besitz vielleicht noch nicht fest: gleich fragen, wenn das Konto da ist.
                if self.owned(result) == .unknown, self.accountBlocker(for: result) == nil { self.checkPurchase(result, quiet: true) }
            }
        }
    }

    /// Setzt ein einzelnes Spiel in beiden Listen neu ein, ohne die ganze Übersicht neu aufzubauen.
    func replace(_ game: Game) {
        if let i = allGames.firstIndex(where: { $0.id == game.id }) { allGames[i] = game }
        if let i = games.firstIndex(where: { $0.id == game.id }) {
            replacingOne = true
            games[i] = game
            replacingOne = false
        }
    }

    static func sourceLookedKey(_ id: String) -> String { "sourceLooked.\(id)" }

    /// Beim Öffnen der Seite eines Spiels. Gibt es das Spiel aus zwei Kaufquellen, wird beim ersten Mal bei beiden
    /// nachgesehen (siehe `checkPurchase`); danach gilt, was sonst gilt: ein älteres „Nein“ wird noch einmal erfragt.
    func purchaseOnOpen(_ game: Game) {
        let key = AppModel.sourceLookedKey(game.id)
        guard game.sources.contains(.steam), game.recipe.source == .meta, !DataLocation.preferences.bool(forKey: key) else {
            // Steam ist gewählt und noch nie gefragt worden (der tägliche Durchgang fragt nur Meta): jetzt fragen.
            if game.recipe.source == .steam, owned(game) == .unknown, steamSignedIn { checkPurchase(game, quiet: true) }
            else { recheckPurchaseIfStale(game) }
            return
        }
        // Gehört das Spiel dem Meta-Konto, bleibt es dabei; gefragt wird Steam dann nicht.
        if owned(game) == .yes { DataLocation.preferences.set(true, forKey: key); return }
        // Kurz nach dem Start steht noch nicht fest, ob ein Meta-Konto angemeldet ist. Dann wird jetzt nicht
        // entschieden, sondern beim nächsten Öffnen der Seite.
        if account == .unknown || account == .checking { return }
        checkPurchase(game, quiet: true, firstOpen: true)
    }

    /// Die Spiele, die zu den gesetzten Filtern passen.
    /// Gemerkt bis zur nächsten Änderung am Zustand (siehe `derived`): Die Übersicht fragt mehrmals je Neuzeichnen.
    var shownGames: [Game] {
        if let known = derived.shownGames { return known }
        let fresh = visible(allGames)
        derived.shownGames = fresh
        return fresh
    }

    /// Aus einer Menge von Spielen die, die zu den gesetzten Filtern passen, in der Reihenfolge der Übersicht.
    func visible(_ games: [Game]) -> [Game] {
        let words = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Was Filter und Sortierung brauchen, einmal je Spiel – nicht bei jedem Vergleich des Sortierens.
        let keyed = games.compactMap { game -> (game: Game, rank: Int, works: Int)? in
            let trust = game.trust, installed = game.installed, downloaded = game.downloaded
            let favourite = isFavourite(game)
            // „Geprüft“ und „Von Nutzern bestätigt“ ergänzen einander; alle anderen Filter engen weiter ein.
            guard ((!filterVerified && !filterCommunity) || (filterVerified && trust == .verified) || (filterCommunity && trust == .community))
                && (!filterInstalled || installed)
                && (!filterDownloaded || (downloaded && !installed))
                && (!filterFavourites || favourite)
                && (!filterFavouritesMissing || (favourite && !downloaded))
                && (!filterMixedReality || game.mixedReality)
                && (!horizonPlusWanted || inChosenHorizonPlus(game))
                && CustomFilters.passes(game.id, filters: customFilters, modes: customFilterModes)
                && (words.isEmpty || game.recipe.title.lowercased().contains(words) || game.recipe.package.lowercased().contains(words))
            else { return nil }
            // Geprüftes zuerst, dann schon Nachgeschlagenes, dann was Nutzer bestätigen, das Ungetestete, zuletzt
            // was nicht läuft – jeweils nach der Zahl derer, die sagen, es läuft, dann nach Namen. So reiht auch
            // der Katalog, damit eine nachgeladene Seite unten anschließt.
            let rank = trust == .verified ? 0 : (game.prepared && trust != .incompatible ? 1 : trust.rawValue + 1)
            return (game, rank, game.catalog?.works ?? 0)
        }
        return keyed.sorted { a, b in
            if a.rank != b.rank { return a.rank < b.rank }
            if a.works != b.works { return a.works > b.works }
            return a.game.recipe.title.localizedCaseInsensitiveCompare(b.game.recipe.title) == .orderedAscending
        }.map(\.game)
    }

    /// Fragt für jedes Store-Spiel, ob das Konto es besitzt – höchstens einmal am Tag je Spiel. Beim ersten
    /// unerwarteten Ergebnis ist Schluss; was bis dahin beantwortet ist, bleibt stehen.
    ///
    /// Meta: eine dokumentierte Abfrage je Spiel, mit Abstand dazwischen. Steam: für die Spiele, bei denen Steam als
    /// Kaufquelle gewählt ist, ein Lauf von Valves Werkzeug mit der Anmeldung des Nutzers, der alle auf einmal fragt.
    func checkOwnership(force: Bool = false) {
        // Der Besitzstand liegt beim Bestand. Fehlt dessen Platte, wird nicht für jedes Spiel neu gefragt, nur
        // weil der gemerkte Stand gerade nicht lesbar ist – und nichts an den verwaisten Pfad geschrieben.
        guard !checkingOwnership, !games.isEmpty, storeBlocker == nil else { return }
        let cache = OwnershipCache(store: paths.store)
        let known = cache.load()
        ownership = known
        let due = account == .signedIn
            ? games.compactMap { $0.recipe.store.appId }.filter { force || OwnershipCache.needsCheck(known[$0]) } : []
        let steamDue = steamSignedIn
            ? games.filter { $0.recipe.source == .steam }.compactMap { $0.recipe.store.steamAppId }
                .filter { force || OwnershipCache.needsCheck(known["steam:\($0)"]) } : []
        guard !due.isEmpty || !steamDue.isEmpty else { return }
        checkingOwnership = true
        let steamAccount = steamAccount
        Task.detached {
            if !due.isEmpty {
                let gate = RequestGate()
                do {
                    let client = MetaClient(token: try TokenStore().read())
                    let user = try await client.me()
                    for app in due {
                        try await gate.waitForTurn()
                        let owned = try await client.ownsApp(appId: app, userId: user)
                        await gate.requestFinished()
                        let now = cache.record(appId: app, owned: owned)
                        await MainActor.run { self.ownership = now }
                    }
                } catch {}
            }
            if !steamDue.isEmpty {
                // Was Steam nicht klar beantwortet, bleibt, wie es war.
                var signedOut = false
                do {
                    let answers = try SteamLicences(account: steamAccount).owned(apps: steamDue)
                    for app in steamDue {
                        guard let owned = answers[app] else { continue }
                        let now = cache.record(appId: "steam:\(app)", owned: owned)
                        await MainActor.run { self.ownership = now }
                    }
                } catch {
                    if case SteamError.notSignedIn = error { signedOut = true }
                }
                if signedOut { await MainActor.run { self.steamSignedInAs = "" } }
            }
            await MainActor.run { self.checkingOwnership = false }
        }
    }

    /// „Kauf prüfen“: fragt jetzt für dieses eine Spiel, ob das Konto es besitzt, und trägt die Antwort ein. Für
    /// jemanden, der ein Spiel gerade gekauft hat und es hier noch als „nicht in deinem Konto“ sieht.
    ///
    /// Gibt es das Spiel aus zwei Kaufquellen, wird erst Meta gefragt (dieselbe dokumentierte Abfrage wie im
    /// täglichen Durchgang, nach `/me`) und dann Steam (Valves Werkzeug, mit der Anmeldung des Nutzers). Gehört es
    /// dem Meta-Konto, bleibt die Quelle Meta und Steam wird nicht gefragt. Gehört es nur dem Steam-Konto, wird
    /// auf Steam gewechselt. Gehört es keinem, bleibt es bei Meta. Zurück zu Meta wird nie von selbst gewechselt.
    func checkPurchase(_ game: Game, quiet: Bool = false, firstOpen: Bool = false) {
        guard let current = game.recipe.source, !checkingPurchase.contains(game.id) else { return }
        if let why = storeBlocker { purchaseNote[game.id] = why; return }
        let metaApp = recipe(of: game, source: .meta)?.store.appId
        let steamApp = recipe(of: game, source: .steam)?.store.steamAppId
        let metaReady = account == .signedIn && metaApp != nil
        let steamReady = steamSignedIn && steamApp != nil
        // Zu Steam gewechselt wird nur, wenn feststeht, dass Meta das Spiel nicht bestätigt: Meta hat „nein“ gesagt,
        // oder es ist gar kein Meta-Konto angemeldet. Solange die Anmeldung noch geprüft wird oder Meta gerade
        // nicht antwortet, bleibt die Quelle, wie sie ist.
        let metaAbsent = account == .signedOut
        // Ohne das Konto der geltenden Quelle – und ohne ein anderes, das gefragt werden könnte – gibt es nichts zu fragen.
        if current == .steam, !steamReady {
            if !quiet { purchaseNote[game.id] = L("Sign in to Steam under “Setup” first.", "Melde dich zuerst unter „Einrichtung“ bei Steam an.") }
            return
        }
        if current == .meta, !metaReady, !steamReady {
            if !quiet { purchaseNote[game.id] = L("For official ownership checks, sign in under Settings → Official Meta downloads. The local library does not need this account.", "Für offizielle Besitzprüfungen unter Einstellungen → Offizielle Meta-Downloads anmelden. Die lokale Bibliothek braucht dieses Konto nicht.") }
            return
        }
        checkingPurchase.insert(game.id)
        purchaseNote[game.id] = nil
        let cache = OwnershipCache(store: paths.store)
        let id = game.id
        let steamAccount = steamAccount
        Task.detached {
            var note: String?
            var metaOwned: Bool?
            var steamOwned: Bool?
            var steamSignedOut = false
            if let metaApp, metaReady {
                do {
                    let client = MetaClient(token: try TokenStore().read())
                    let user = try await client.me()
                    let answer = try await client.ownsApp(appId: metaApp, userId: user)
                    metaOwned = answer
                    let now = cache.record(appId: metaApp, owned: answer)
                    await MainActor.run { self.ownership = now }
                } catch {
                    if !quiet, current == .meta { note = L("Meta could not be asked: \(Redaction.redact("\(error)"))", "Meta ließ sich nicht fragen: \(Redaction.redact("\(error)"))") }
                }
            }
            // Steam: wo es die geltende Quelle ist, und sonst nur, wenn Meta das Spiel nicht bestätigt hat.
            if let steamApp, steamReady, current == .steam || metaOwned != true {
                do {
                    if let answer = try SteamLicences(account: steamAccount).owned(apps: [steamApp])[steamApp] {
                        steamOwned = answer
                        let now = cache.record(appId: "steam:\(steamApp)", owned: answer)
                        await MainActor.run { self.ownership = now }
                    } else if !quiet, current == .steam {
                        note = "\(SteamError.unclearOwnership)"
                    }
                } catch {
                    if case SteamError.notSignedIn = error { steamSignedOut = true }
                    if !quiet, current == .steam { note = "\(error)" }
                }
            }
            let toSteam = current == .meta && steamOwned == true && (metaOwned == false || (metaOwned == nil && metaAbsent))
            if toSteam {
                note = L("This game is not in your Meta account, but it is in your Steam account. The purchase source is now Steam.",
                         "Dieses Spiel gehört nicht zu deinem Meta-Konto, aber zu deinem Steam-Konto. Die Kaufquelle ist jetzt Steam.")
            } else if note == nil, !quiet {
                // Ungefragt (beim Öffnen der Seite) wird ein weiteres „Nein“ nicht eigens erläutert.
                if current == .meta, metaOwned == false {
                    note = L("Meta says this game is not in the account you are signed in with. A new purchase can take a few minutes to show up; an alternate account can be selected under Settings → Official Meta downloads.",
                             "Meta sagt, dass dieses Spiel nicht zu dem Konto gehört, mit dem du angemeldet bist. Ein neuer Kauf kann ein paar Minuten brauchen, bis er sichtbar ist; ein anderes Konto lässt sich unter Einstellungen → Offizielle Meta-Downloads wählen.")
                    if steamApp != nil {
                        note! += steamOwned == false
                            ? L(" Steam does not have it in your account either.", " Auch bei Steam gehört es nicht zu deinem Konto.")
                            : L(" If you bought it on Steam, sign in to Steam under “Setup” and check again.", " Hast du es bei Steam gekauft, melde dich unter „Einrichtung“ bei Steam an und prüfe noch einmal.")
                    }
                } else if current == .steam, steamOwned == false {
                    note = L("Steam says this game is not in the account you are signed in with. A game bought with another Steam account needs that account under “Setup”.",
                             "Steam sagt, dass dieses Spiel nicht zu dem Konto gehört, mit dem du angemeldet bist. Ein Spiel, das mit einem anderen Steam-Konto gekauft wurde, braucht dieses Konto unter „Einrichtung“.")
                }
            }
            let final = note
            let bought = metaOwned == true
            let settled = metaOwned == true || (steamOwned != nil && (metaOwned == false || metaAbsent))
            let lost = steamSignedOut
            await MainActor.run {
                self.checkingPurchase.remove(id)
                self.purchaseNote[id] = final
                if lost { self.steamSignedInAs = "" }
                if firstOpen, settled { DataLocation.preferences.set(true, forKey: AppModel.sourceLookedKey(id)) }
                guard let game = self.allGames.first(where: { $0.id == id }) else { return }
                if toSteam {
                    self.chooseSource(game, .steam)
                    self.purchaseNote[id] = final
                }
                // Ein ungetestetes Spiel, das nun doch zum Konto gehört: gleich nachschlagen, woraus es besteht.
                if bought, game.draft, !game.prepared { self.prepare(game) }
            }
        }
    }

    /// Beim Öffnen der Seite eines Spiels: Ein „Nein“, das älter als zehn Minuten ist, wird noch einmal erfragt.
    /// Nicht bei einem ungetesteten Spiel, das noch nachgeschlagen wird – dort stellt `prepare` dieselbe Frage.
    func recheckPurchaseIfStale(_ game: Game) {
        guard let key = OwnershipCache.key(for: game.recipe), let record = ownership[key], !record.owned,
              Date().timeIntervalSince(record.checked) > 600, accountBlocker(for: game) == nil, !(game.draft && !game.prepared) else { return }
        checkPurchase(game, quiet: true)
    }

    // MARK: Auswahl je Spiel

    func options(for game: Game) -> GameOptions {
        options[game.id] ?? AppModel.defaultOptions(recipe: game.recipe, store: paths.store)
    }

    func setOptions(_ value: GameOptions, for game: Game) {
        let xrBefore = options(for: game).xrPrediction == true
        options[game.id] = value
        if let data = try? JSONEncoder().encode(options) { DataLocation.preferences.set(data, forKey: "gameOptions") }
        // Die XR-Vorhersage entscheidet mit, ob ein installierter Bau aktuell ist: den Stand dieses Spiels gleich neu
        // bestimmen, nicht erst bei der nächsten Bestandsaufnahme.
        if (value.xrPrediction == true) != xrBefore { refreshStatus(of: game.id) }
    }

    /// Opens the Beat Saber details where the existing runtime build toggle lives.
    func openAppleMusicSearchOptions(for game: Game?) {
        section = .games
        guard let game else {
            gamePath = []
            notice = "Beat Saber is not in the loaded game list yet. Load the library before configuring Apple Music Search."
            return
        }
        gamePath = [game.id]
    }

    /// The Apple Music Search navigation page edits the same per-game build option shown in game details.
    func setAppleMusicSearchEnabled(_ enabled: Bool, for game: Game) {
        var value = options(for: game)
        value.coreMods = enabled
        setOptions(value, for: game)
    }

    /// Bestimmt den Stand eines Spiels neu, mit dem, was gerade bekannt ist (Gerät, Toolchain, Einstellungen).
    func refreshStatus(of id: String) {
        guard var fresh = allGames.first(where: { $0.id == id }) ?? games.first(where: { $0.id == id }) else { return }
        fresh.status = GameStatus.of(recipe: fresh.recipe, store: paths.store, apps: installedApps, toolchainVersion: toolchain(for: fresh)?.appRevision(target: KleptonRecipeCompatibility.resolve(fresh.recipe).toolchain.target) ?? toolchainRevision,
                                     pin: toolchainChoices.games[id], bundlePrefix: bundlePrefix,
                                     otherSourceBuilds: Set(fresh.otherSourceBuilds),
                                     experimental: experimentalExpected, metalFX: metalFXExpected,
                                     xrPrediction: xrPredictionExpected(for: id))
        replace(fresh)
    }

    /// `xrPredictionExpected(supported:)` für ein Spiel, aus den Optionen im Speicher.
    func xrPredictionExpected(for id: String) -> Bool? {
        guard xrPredictionSupported == true else { return nil }
        return options[id]?.xrPrediction == true
    }

    /// Wählbare Dateien, die das Rezept unter eigenem Namen anbietet – etwa eine Sprachausgabe von Fans.
    nonisolated static func extras(of recipe: Recipe) -> [RecipeFile] {
        recipe.files.filter { !$0.required && $0.locale == nil && $0.title != nil }
    }

    func inLibrary(_ file: RecipeFile, of game: Game) -> Bool {
        if case .present(let size) = paths.store.state(of: file, in: game.recipe) { return file.size == nil || file.size == size }
        return false
    }

    /// Angehakt, vom Nutzer bereitzustellen (oder aus seinem Steam-Konto zu holen), und noch nicht im Bestand.
    func missingExtras(for game: Game) -> [RecipeFile] {
        let extras = AppModel.extras(of: game.recipe)
        guard !extras.isEmpty else { return [] }
        let chosen = Set(options(for: game).optionalNames)
        return extras.filter { chosen.contains($0.name) && $0.source?.kind == .user && !inLibrary($0, of: game) }
    }

    /// Ohne eigene Wahl: was schon im Bestand liegt, bleibt gewählt; sonst die Sprache des Systems, wenn es
    /// dafür Dateien gibt. Englisch braucht bei Sprachpaketen nichts – es ist die Fassung des Spiels selbst.
    nonisolated static func defaultOptions(recipe: Recipe, store: ContentStore,
                                           preferred: [String] = Locale.preferredLanguages) -> GameOptions {
        let optional = recipe.files.filter { !$0.required }
        func present(_ f: RecipeFile) -> Bool { if case .present = store.state(of: f, in: recipe) { return true }; return false }
        var result = GameOptions()
        var locales = Set(optional.filter(present).compactMap(\.locale))
        let available = Set(optional.compactMap(\.locale))
        if locales.isEmpty {
            for language in preferred {
                let code = language.split(separator: "-").first.map(String.init) ?? language
                if let match = available.first(where: { $0 == language }) ?? available.sorted().first(where: { $0 == code || $0.hasPrefix(code + "-") }) {
                    locales.insert(match)
                    break
                }
                if code == "en" { break }
            }
        }
        result.locales = locales.sorted()
        result.optionalNames = optional.filter { $0.locale == nil && present($0) }.map(\.name).sorted()
        return result
    }

    /// Wie weit der Download eines Auftrags ist: vorhandene und angefangene Bytes gegen die bekannte Summe.
    func downloadProgress(_ job: Job) -> (done: Int64, total: Int64)? {
        var selection = FetchSelection(locales: Set(job.request.locales), optionalNames: Set(job.request.optionalNames),
                                       withheld: paths.store.withheld(for: job.recipe))
        if job.recipe.addons?.kind == .deliveredAssets, job.request.addons,
           let purchases = PurchaseRecord.load(store: paths.store, recipe: job.recipe) { selection.ownedSKUs = Set(purchases.skus) }
        var done: Int64 = 0, total: Int64 = 0
        for file in FetchPlan.wantedFiles(recipe: job.recipe, selection: selection) where file.source?.kind != .user {
            guard let size = file.size else { continue }
            total += size
            switch paths.store.state(of: file, in: job.recipe) {
            case .present(let have), .partial(let have): done += min(have, size)
            case .missing: break
            }
        }
        return total > 0 ? (done, total) : nil
    }

    var languageChoice: LanguageChoice {
        get { LanguageChoice(rawValue: languageRaw) ?? .system }
        set {
            languageRaw = newValue.rawValue
            applyLanguage()
            // Was schon als Satz im Zustand liegt (Gerät, Xcode, Toolchain), entsteht beim Prüfen neu.
            refresh()
        }
    }

    /// Stellt die Sprache ein: die gewählte, sonst die erste bevorzugte des Systems. Eine feste Wahl wird
    /// auch als `AppleLanguages` dieses Programms hinterlegt, damit die Menüs von macOS beim nächsten Start
    /// dieselbe Sprache haben.
    private func applyLanguage() {
        let choice = LanguageChoice(rawValue: languageRaw) ?? .system
        let chosen: Language
        if choice == .system {
            DataLocation.preferences.removeObject(forKey: "AppleLanguages")
            let system = CFPreferencesCopyValue("AppleLanguages" as CFString, kCFPreferencesAnyApplication,
                                                kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String]
            chosen = L10n.systemLanguage(preferred: system ?? Locale.preferredLanguages)
        } else {
            chosen = Language(rawValue: choice.rawValue) ?? .en
            DataLocation.preferences.set([chosen.rawValue], forKey: "AppleLanguages")
        }
        L10n.language = chosen
        language = chosen
    }

    /// Das Präfix, unter dem die Spiele installiert werden: das gewählte, sonst der Standard.
    var bundlePrefix: String {
        customBundlePrefix.isEmpty ? Toolchain.defaultBundlePrefix(freeTeam: team?.free == true ? teamId : nil) : customBundlePrefix
    }

    var teamValid: Bool { teamId.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil }
    /// Das gewählte Team, soweit Xcode es kennt.
    var team: Probe.Team? { teamCandidates.first { $0.id == teamId } }
    /// Gemerkt bis zur nächsten Änderung am Zustand (siehe `derived`): Die Übersicht fragt bei jedem Neuzeichnen
    /// danach, und jedes Mal den Ordner der Toolchains zu lesen kostet.
    var toolchain: Toolchain? {
        if let known = derived.toolchain { return known }
        let fresh = paths.toolchain()
        derived.toolchain = .some(fresh)
        return fresh
    }

    /// Was einer Installation im Weg steht, als Satz mit der nächsten Handlung – oder `nil`.
    func blocker(for game: Game) -> String? {
        if let why = storeBlocker { return why }
        if xcodeProblem != nil { return L("Xcode is missing. “Setup” tells you what to do.", "Xcode fehlt. Unter „Einrichtung“ steht, was zu tun ist.") }
        if toolchain == nil { return "Klepton 850 + TLS168 indisponível. Operação bloqueada, sem fallback." }
        if !teamValid { return L("The Apple team ID is still missing (see “Setup”).", "Die Apple-Team-ID fehlt noch (siehe „Einrichtung“).") }
        if device == nil { return deviceProblem ?? L("The Vision Pro is not reachable.", "Die Vision Pro ist nicht erreichbar.") }
        if game.draft, !game.prepared {
            return prepareNote[game.id] ?? L("The files of this game have not been looked up yet.", "Die Dateien dieses Spiels sind noch nicht nachgeschlagen.")
        }
        if let why = accountBlocker(for: game) { return why }
        if owned(game) == .no { return notOwnedText(game) }
        if game.otherSourceInstalled { return otherSourceText(game) }
        if let why = freeAccountBlocker(for: game) { return why }
        if !game.status.userProvidedMissing.isEmpty { return L("Files that you provide yourself are missing (see below).", "Es fehlen Dateien, die du selbst bereitstellst (siehe unten).") }
        if let extra = missingExtras(for: game).first {
            let name = extra.title?.text ?? extra.name
            return L("“\(name)” is ticked but not on this Mac yet (see “Optional Content”).",
                     "„\(name)“ ist angehakt, liegt aber noch nicht auf diesem Mac (siehe „Wählbare Inhalte“).")
        }
        // Ein Entwurf, der ohne Toolchain nachgeschlagen wurde, nennt noch keinen Mindeststand; der wird beim Anlegen
        // des Auftrags eingesetzt.
        guard let t = toolchain(for: game) else {
            return "A receita \(game.recipe.id) não é compatível com o Klepton 850 + TLS168 verificado ou seu minCommit não foi comprovado. Nenhum fallback para a 750 foi tentado."
        }
        if !game.recipe.toolchain.minCommit.isEmpty, !t.satisfies(minCommit: game.recipe.toolchain.minCommit) {
            return "A receita exige o commit \(game.recipe.toolchain.minCommit), que não está presente no Klepton 850 + TLS168 verificado. Nenhum fallback para a 750 foi tentado; a receita requer adaptação validada."
        }
        if isBusy(game.id) { return L("A job for this game is already running.", "Für dieses Spiel läuft schon ein Auftrag.") }
        // Platz für den Download, mit zwei Gigabyte Luft für Bau und Zwischenstände.
        if let free = freeBytes, game.status.bytesToDownload > 0, game.status.bytesToDownload + 2_000_000_000 > free {
            return L("Not enough free space on this Mac: \(Installer.gigabytes(game.status.bytesToDownload)) to download, \(Installer.gigabytes(free)) free.",
                     "Auf diesem Mac ist zu wenig Platz: \(Installer.gigabytes(game.status.bytesToDownload)) zu laden, \(Installer.gigabytes(free)) frei.")
        }
        return nil
    }

    func isBusy(_ recipeId: String) -> Bool {
        jobs.contains {
            $0.recipe.id == recipeId && ($0.id == runningJob || queued.contains($0.id)
                || $0.state == .waiting || $0.state == .running)
        }
    }

    func hasActiveEquivalentJobForPresentation(_ job: Job) -> Bool {
        paths.jobs.all().contains { other in
            other.id != job.id && other.recipe.id == job.recipe.id
                && other.request.localAPKVariantID == job.request.localAPKVariantID
                && other.steps == job.steps
                && (other.id == runningJob || queued.contains(other.id)
                    || resumingJobIDs.contains(other.id)
                    || (other.state == .running && other.id != runningJob))
        }
    }

    func queueExplanation(for job: Job) -> String? {
        switch phase(of: job) {
        case .pending:
            if hasActiveEquivalentJobForPresentation(job) {
                return "Outro Job da mesma variante e operação já está ativo; aguarde antes de iniciar este duplicado preservado."
            }
            return "Job recuperado do disco. Jobs antigos não iniciam automaticamente; use ‘Iniciar Build only’ quando quiser executar este Job."
        case .queued:
            if let runningJob, runningJob != job.id { return "Aguardando o outro Job em execução terminar." }
            if runningTask != nil, runningJob == nil { return "Aguardando a liberação do executor de Jobs." }
            if !preparingLocalVariantIDs.isEmpty { return "Aguardando a preparação local em andamento terminar." }
            if !runJobsAutomatically { return "Execução automática pausada; inicie este Job manualmente." }
            return "Aguardando sua vez na fila."
        case .interrupted:
            return "Job interrompido. Retome manualmente para continuar da primeira etapa pendente."
        case .running, .finished, .cancelled, .stopped:
            return nil
        }
    }

    // MARK: Lage feststellen

    func refresh() {
        guard !refreshing, checkingConnectionJobID == nil else { return }
        // Auf der Seite der Datenverwaltung heißt „neu laden“ auch: neu zählen.
        if section == .data { scanStorage() }
        refreshing = true
        let paths = paths
        let prefix = bundlePrefix
        let wanted = chosenDevice.isEmpty ? nil : chosenDevice
        Task.detached(priority: .userInitiated) {
            let snapshot = Probe.run(paths: paths, bundlePrefix: prefix, preferredDevice: wanted)
            await MainActor.run {
                self.apply(snapshot)
                self.refreshing = false
            }
        }
    }

    /// Loads the bundled/local recipe list only. This is deliberately independent of device discovery,
    /// the project catalogue, Meta credentials and any network service.
    func loadLocalRecipes() {
        guard let directory = paths.recipes else {
            localRecipeLoadError = L("No local recipe directory is available.", "Kein lokaler Rezeptordner verfügbar.")
            return
        }
        let savedRecipeID = selectedLocalRecipeID
        let explicitlySelected = localRecipeSelectionExplicit
        let variants = localVariantStore
        Task.detached(priority: .userInitiated) {
            do {
                // The local APK importer/preparer is for Android APK recipes. Linux/tree-only recipes remain
                // available in optional Discover and their existing official workflows.
                let shipped = RecipeStore(directory: directory)
                let choices = StoreUpdate.Choices.load()
                let alternatives = shipped.loadVariants()
                let recipes = try shipped.loadAll().map { base in
                    alternatives.first { $0.id == base.id && $0.source == base.source
                        && $0.versionCode == choices.versions[base.id] } ?? base
                }.filter { $0.files.contains(where: { $0.role == "apk" }) }
                let provisional = try LocalProvisionalRecipeStore(root: DataLocation.base.appendingPathComponent("provisional-recipes", isDirectory: true)).loadAll()
                let localGeneratedRecipes = provisional.compactMap { $0.experimentalRecipe ?? $0.communityRecipe }
                    .filter { candidate in !recipes.contains(where: { $0.id == candidate.id }) }
                let combined = (recipes + localGeneratedRecipes).sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
                let restoration = LocalCommunitySelectionRestoration.resolve(savedRecipeID: savedRecipeID,
                    explicitlySelected: explicitlySelected, provisionalRecords: provisional,
                    recipes: combined, variants: variants)
                await MainActor.run {
                    self.localRecipes = combined
                    self.localProvisionalRecipes = provisional
                    self.localRecipeLoadError = nil
                    self.localCommunitySelectionChoices = []
                    self.localCommunitySelectionMessage = nil
                    if case .restored(let choice) = restoration {
                        self.selectedLocalRecipeID = choice.recipeID
                        self.localRecipeSelectionExplicit = false
                        self.localImport.recipeID = choice.recipeID
                        self.localImport.variantID = choice.variantID
                    } else if case .choose(let choices, let message) = restoration {
                        self.localCommunitySelectionChoices = choices
                        self.localCommunitySelectionMessage = message
                    } else if case .verifyAgain(let message) = restoration {
                        self.localCommunitySelectionMessage = message
                    }
                    if self.selectedLocalRecipeID.isEmpty || (!self.localRecipes.contains(where: { $0.id == self.selectedLocalRecipeID }) && !provisional.contains(where: { $0.id == self.selectedLocalRecipeID })) {
                        self.selectedLocalRecipeID = self.localRecipes.first?.id ?? provisional.first?.id ?? ""
                        self.localRecipeSelectionExplicit = false
                    }
                    self.localLibraryRevision += 1
                }
            } catch {
                await MainActor.run { self.localRecipeLoadError = "\(error)" }
            }
        }
    }

    func selectLocalLibraryItem(_ id: String, isProvisional: Bool) {
        selectedLocalRecipeID = id
        localRecipeSelectionExplicit = isProvisional
        localCommunitySelectionMessage = nil
        localCommunitySelectionChoices = []
        localImport.recipeID = isProvisional ? nil : id
        localImport.variantID = nil
    }

    func selectLocalCommunityVariant(_ choice: LocalCommunitySelectionChoice) {
        selectedLocalRecipeID = choice.recipeID
        localRecipeSelectionExplicit = false
        localImport.recipeID = choice.recipeID
        localImport.variantID = choice.variantID
        localCommunitySelectionMessage = nil
        localCommunitySelectionChoices = []
    }

    var visibleLocalRecipes: [Recipe] {
        localRecipes.filter { LocalRecipeFilters.passes($0.id, filters: localRecipeFilters, modes: localRecipeFilterModes) }
    }

    @discardableResult
    func createLocalRecipeFilter(named name: String) -> Bool {
        guard LocalRecipeFilters.nameProblem(name, in: localRecipeFilters) == nil else { return false }
        let ids = selectedLocalRecipeID.isEmpty ? [] : [selectedLocalRecipeID]
        localRecipeFilters.append(LocalRecipeFilter(name: LocalRecipeFilters.cleanName(name), recipeIDs: Set(ids)))
        return true
    }

    func setLocalRecipeMembership(_ recipeID: String, in filterID: String, member: Bool) {
        guard let index = localRecipeFilters.firstIndex(where: { $0.id == filterID }) else { return }
        if member { localRecipeFilters[index].recipeIDs.insert(recipeID) }
        else { localRecipeFilters[index].recipeIDs.remove(recipeID) }
        keepSelectedRecipeVisibleIfPossible()
    }

    func setLocalRecipeFilterMode(_ filterID: String, mode: LocalRecipeFilterMode) {
        localRecipeFilterModes[filterID] = mode == .off ? nil : mode
        keepSelectedRecipeVisibleIfPossible()
    }

    func deleteLocalRecipeFilter(_ filterID: String) {
        localRecipeFilters.removeAll { $0.id == filterID }
        localRecipeFilterModes[filterID] = nil
        keepSelectedRecipeVisibleIfPossible()
    }

    private func keepSelectedRecipeVisibleIfPossible() {
        if !visibleLocalRecipes.contains(where: { $0.id == selectedLocalRecipeID }),
           let first = visibleLocalRecipes.first {
            selectedLocalRecipeID = first.id
        }
    }

    private func apply(_ s: Probe.Snapshot) {
        // Vor den Spielen: daraus wird die Liste aller Spiele gebaut, und die braucht den neuen Stand des Geräts.
        installedApps = s.apps
        toolchainRevision = s.toolchainRevision
        experimentalExpected = s.experimentalExpected
        metalFXExpected = s.metalFXExpected
        if xrPredictionSupported != s.xrPredictionSupported { xrPredictionSupported = s.xrPredictionSupported }
        toolchainChoices = s.toolchainChoices
        games = s.games
        loadProblem = s.loadProblem
        device = s.device
        devices = s.devices
        deviceProblem = s.deviceProblem
        toolchainText = s.toolchainText
        toolPresent = s.toolPresent
        xcodeText = s.xcodeText
        xcodeProblem = s.xcodeProblem
        teamCandidates = s.teamCandidates
        freeBytes = s.freeBytes
        // Genau ein bezahltes Team: das ist es. Sonst entscheidet der Nutzer.
        let paid = s.teamCandidates.filter { !$0.free }
        if teamId.isEmpty, paid.count == 1 { teamId = paid[0].id }
        saveSnapshots = s.saves
        reloadJobs()
        ownership = OwnershipCache(store: paths.store).load()
        if selectedLocalRecipeID.isEmpty || (!localRecipes.contains(where: { $0.id == selectedLocalRecipeID }) && !localProvisionalRecipes.contains(where: { $0.id == selectedLocalRecipeID })) {
            selectedLocalRecipeID = localRecipes.first?.id ?? localProvisionalRecipes.first?.id ?? ""
        }
    }

    func reloadJobs() {
        jobs = paths.jobs.all()
        // Wer wartet, kommt in der Reihenfolge der Liste dran, von unten nach oben – so gilt auch, was der Nutzer
        // dort umstellt, und nicht, in welcher Reihenfolge angeklickt wurde.
        let order = JobStore.runOrder(of: queued, in: jobs)
        if order != queued { queued = order }
        if selectedJob == nil || !jobs.contains(where: { $0.id == selectedJob }) { selectedJob = jobs.first?.id }
    }

    /// Fragt Meta, ob der hinterlegte Token gilt. Eine einzige Abfrage; gezeigt wird nie mehr als ja oder nein.
    func checkAccount() {
        guard account != .checking else { return }
        account = .checking
        Task.detached {
            let state: AccountState
            let offline: Bool
            do {
                let token = try TokenStore().read()
                do {
                    _ = try await MetaClient(token: token).me()
                    state = .signedIn
                    offline = false
                } catch MetaError.transport(let why) {
                    state = .problem(L("No connection to Meta yet (\(why)). AVP Play tries again by itself.",
                                       "Noch keine Verbindung zu Meta (\(why)). AVP Play versucht es von selbst noch einmal."))
                    offline = true
                } catch {
                    state = .problem(Redaction.redact("\(error)"))
                    offline = false
                }
            } catch {
                state = .signedOut
                offline = false
            }
            await MainActor.run {
                self.accountOffline = offline
                if offline { self.scheduleOfflineRetry() } else { self.offlineRetries = 0 }
                self.account = state
                self.checkOwnership()
            }
        }
    }

    func signOut() {
        accountOffline = false
        offlineRetries = 0
        _ = try? TokenStore().delete()
        account = .signedOut
        OwnershipCache(store: paths.store).clear()
        ownership = [:]
    }

    // MARK: Metas Werkzeug

    static let toolPage = URL(string: "https://developers.meta.com/horizon/resources/publish-reference-platform-command-line-utility/")!

    /// Öffnet Metas Seite im Browser und hält danach eine Weile im Ordner „Downloads“ Ausschau: Sobald die
    /// Datei dort liegt, richtet die App sie ein. Geladen wird beim Nutzer, im Browser, zu Metas Bedingungen –
    /// die App lädt das Werkzeug nie selbst und bringt es nicht mit.
    func openToolPage() {
        NSWorkspace.shared.open(AppModel.toolPage)
        toolNote = L("Download the macOS version on Meta’s page. AVP Play picks it up from your Downloads folder as soon as it is there.",
                     "Lade auf Metas Seite die Fassung für macOS. AVP Play übernimmt sie aus deinem Ordner „Downloads“, sobald sie dort liegt.")
        toolWatch?.cancel()
        lookingForTool = true
        toolWatch = Task { [weak self] in
            for _ in 0..<450 {                      // 15 Minuten
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled, !self.toolPresent else { break }
                if await self.adoptToolFromDownloads(quiet: true) { break }
            }
            self?.lookingForTool = false
        }
    }

    /// Sucht jetzt im Ordner „Downloads“ und sagt, was dabei herauskam.
    func findTool() {
        Task { await adoptToolFromDownloads(quiet: false) }
    }

    @discardableResult
    private func adoptToolFromDownloads(quiet: Bool) async -> Bool {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let outcome: (ok: Bool, note: String?) = await Task.detached {
            // macOS fragt beim ersten Zugriff auf „Downloads“ um Erlaubnis. Wurde sie verweigert, lässt sich
            // der Ordner nicht lesen – dann bleibt die Dateiauswahl, die diese Erlaubnis nicht braucht.
            guard (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) != nil else {
                return (false, quiet ? nil : L("AVP Play is not allowed to look into your Downloads folder. Use “Choose File …” instead, or allow it under System Settings › Privacy & Security › Files and Folders.",
                                               "AVP Play darf nicht in deinen Ordner „Downloads“ sehen. Nimm stattdessen „Datei auswählen …“, oder erlaube es unter Systemeinstellungen › Datenschutz & Sicherheit › Dateien und Ordner."))
            }
            let candidates = MetaTool.downloads(in: folder)
            guard !candidates.isEmpty else {
                return (false, quiet ? nil : L("There is no file named “ovr-platform-util” in your Downloads folder yet.",
                                               "In deinem Ordner „Downloads“ liegt noch keine Datei namens „ovr-platform-util“."))
            }
            var problem = ""
            for file in candidates {
                do {
                    try MetaTool.adopt(from: file)
                    return (true, nil)
                } catch { problem = "\(error)" }
            }
            return (false, problem)
        }.value
        finishToolSetup(ok: outcome.ok, note: outcome.note)
        return outcome.ok
    }

    /// Richtet eine vom Nutzer gewählte Datei ein.
    func adoptTool(from file: URL) {
        Task {
            let problem: String? = await Task.detached {
                do { try MetaTool.adopt(from: file); return nil } catch { return "\(error)" }
            }.value
            finishToolSetup(ok: problem == nil, note: problem)
        }
    }

    private func finishToolSetup(ok: Bool, note: String?) {
        if ok {
            toolWatch?.cancel()
            lookingForTool = false
            toolPresent = true
            toolNote = L("Meta’s tool is set up. You can sign in now.", "Metas Werkzeug ist eingerichtet. Du kannst dich jetzt anmelden.")
        } else if let note {
            toolNote = note
        }
    }

    // MARK: Dateien des Nutzers übernehmen

    /// Sucht in einem vom Nutzer gewählten Ordner nach den Dateien und Ordnern, die das Rezept verlangt.
    func adopt(_ game: Game, from folder: URL) {
        let paths = paths
        notice = L("Searching the folder …", "Ordner wird durchsucht …")
        Task.detached {
            var found: [String] = []
            var problem: String?
            do {
                let r = try Adopter(store: paths.store).adopt(recipe: game.recipe, from: [folder])
                found += r.adopted
                if !r.mismatched.isEmpty { problem = L("Not the expected version: \(r.mismatched.joined(separator: ", "))", "Nicht die erwartete Fassung: \(r.mismatched.joined(separator: ", "))") }
                if !(game.recipe.trees ?? []).isEmpty {
                    found += try TreeStore(store: paths.store).adopt(recipe: game.recipe, from: [folder]).adopted
                }
            } catch {
                problem = "\(error)"
            }
            let text = problem ?? (found.isEmpty ? L("Nothing matching was found in this folder.", "In diesem Ordner wurde nichts Passendes gefunden.")
                                                 : L("Added: \(found.joined(separator: ", "))", "Übernommen: \(found.joined(separator: ", "))"))
            await MainActor.run {
                self.notice = text
                self.refresh()
            }
        }
    }

    // MARK: Toolchain

    /// Das Programmpaket bringt eine Toolchain mit. Ist keine installiert oder nur eine ältere, wird die
    /// mitgelieferte installiert – geprüft wie jedes andere Paket (Größe, Prüfsumme, Inhalt).
    func installBundledToolchainIfNewer() {
        if let runtime = Bundle.main.resourceURL?.appendingPathComponent("optional-runtime", isDirectory: true),
           FileManager.default.fileExists(atPath: runtime.appendingPathComponent(OptionalRuntime850.archiveName).path),
           FileManager.default.fileExists(atPath: runtime.appendingPathComponent("surreal-sdk.tar.gz").path) {
            let paths = paths
            Task.detached {
                let text: String
                do {
                    if let installed = paths.packager.verified850() {
                        _ = try OptionalRuntime850.verifyFullIntegrity(of: installed)
                        try OptionalRuntime850.verifySDK(at: installed.root)
                    } else {
                        let installed = try OptionalRuntime850.install(resources: runtime, packager: paths.packager)
                        try RuntimePolicy177.requireSource(installed)
                    }
                    await MainActor.run {
                        self.refresh()
                    }
                    return
                } catch {
                    text = L("The bundled Klepton 850 + TLS168 runtime could not be verified or installed: \(error)",
                             "Die enthaltene Klepton-850-+TLS168-Runtime konnte nicht geprüft oder installiert werden: \(error)")
                }
                await MainActor.run {
                    self.notice = text
                    self.refresh()
                }
            }
            return
        }
        guard let folder = Bundle.main.resourceURL?.appendingPathComponent("toolchain", isDirectory: true),
              let archive = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?
                  .first(where: { $0.lastPathComponent.hasSuffix(".tar.gz") }) else { return }
        let paths = paths
        Task.detached {
            guard let bundled = Paths.manifest(beside: archive) else { return }
            if let installed = paths.packager.installed().first?.manifest, installed.version >= bundled.version {
                await MainActor.run { self.removeOlderToolchainsAutomatically() }
                return
            }
            let text: String
            do {
                let t = try paths.packager.install(archive: archive)
                text = L("Toolchain version \(t.version()) has been installed.", "Toolchain Version \(t.version()) wurde installiert.")
            } catch {
                text = L("The toolchain that comes with this app could not be installed: \(error)",
                         "Die mitgelieferte Toolchain konnte nicht installiert werden: \(error)")
            }
            await MainActor.run {
                self.notice = text
                self.refresh()
                self.removeOlderToolchainsAutomatically()
            }
        }
    }

    /// Räumt ältere Toolchains weg, ohne dass jemand darum bitten muss: nach dem Start, nach dem Installieren einer
    /// neueren und nach jedem Auftrag. In der neuesten fällt dabei weg, was Spiele beim Bauen hinterlassen haben,
    /// deren letzter Bau über eine Woche her ist. Eine Toolchain wächst mit jedem gebauten Spiel um Gigabytes, und gebaut wird
    /// immer mit der neuesten – die älteren braucht nur noch ein Auftrag, der gerade wartet oder läuft. Baut oder
    /// kopiert gerade irgendein AVP-Play-Prozess (auch der Hintergrunddienst), passiert nichts; der nächste Anlass
    /// holt es nach.
    nonisolated static let buildLeftoverAge: TimeInterval = 7 * 24 * 3600

    func removeOlderToolchainsAutomatically() {
        guard autoRemoveOldToolchains, runningJob == nil else { return }
        // Historical Jobs/builds can be the sole evidence for a working installed game.
        guard !jobs.contains(where: { $0.completed.contains(.build) || $0.completed.contains(.buildOnly) }) else { return }
        let paths = paths
        let active = jobs.filter { $0.state == .waiting || $0.state == .running }
        // Was für ein Spiel gewählt ist oder gerade für eines geladen wird, bleibt wie das, womit ein Auftrag begann.
        let open = Set(active.map(\.toolchainCommit)).union(keptToolchainCommits), busy = Set(active.map(\.recipe.toolchain.target))
        // Die Kopie des APK heißt nicht bei jedem Spiel wie sein Target; den Namen kennt das Rezept.
        var apkNames: [String: String] = [:]
        for recipe in games.map(\.recipe) + jobs.map(\.recipe) {
            if let name = recipe.files.first(where: { $0.role == "apk" })?.localName { apkNames[recipe.toolchain.target] = name }
        }
        Task.detached(priority: .utility) {
            guard let cleared = paths.packager.pruneWhenIdle(protecting: open, leftoversOlderThan: AppModel.buildLeftoverAge,
                                                             apkNames: apkNames, busyTargets: busy),
                  !cleared.isEmpty else { return }
            var parts: [String] = []
            if !cleared.toolchains.isEmpty {
                let names = cleared.toolchains.map { String($0.version) }.joined(separator: ", ")
                parts.append(cleared.toolchains.count == 1
                    ? L("an older toolchain (version \(names))", "eine ältere Toolchain (Version \(names))")
                    : L("\(cleared.toolchains.count) older toolchains (versions \(names))", "\(cleared.toolchains.count) ältere Toolchains (Versionen \(names))"))
            }
            if !cleared.games.isEmpty {
                parts.append(cleared.games.count == 1
                    ? L("the build leftovers of one game built more than a week ago", "die Bau-Reste eines Spiels, das vor über einer Woche gebaut wurde")
                    : L("the build leftovers of \(cleared.games.count) games built more than a week ago", "die Bau-Reste von \(cleared.games.count) Spielen, die vor über einer Woche gebaut wurden"))
            }
            let what = parts.joined(separator: L(" and ", " und "))
            await MainActor.run {
                self.notice = L("Tidied up: \(what) removed from this Mac. Nothing on the Vision Pro or among the downloads was touched.",
                                "Aufgeräumt: \(what) von diesem Mac entfernt. Vision Pro und Downloads sind unberührt.")
                self.scanStorage()
            }
        }
    }

    /// Warum nicht installiert wird, solange dasselbe Spiel aus der anderen Kaufquelle auf dem Gerät liegt.
    func otherSourceText(_ game: Game) -> String {
        let new = AppModel.name(game.recipe.source), old = game.recipe.source == .steam ? "Meta" : "Steam"
        return L("The \(old) version of this game is on the Vision Pro. The \(new) version is a different build with its own files and its own saved games and cannot be installed over it. Remove the game on the headset first (press and hold its icon, “Remove App”). Note: removing the app also deletes the saved games of the \(old) version on the headset. Copies of them that this app has already fetched stay on this Mac.",
                 "Auf der Vision Pro liegt die \(old)-Fassung dieses Spiels. Die \(new)-Fassung ist ein anderer Stand mit eigenen Dateien und eigenen Spielständen und lässt sich nicht darüber installieren. Entferne das Spiel zuerst auf dem Headset (Symbol gedrückt halten, „App entfernen“). Achtung: Beim Entfernen löscht das Headset auch die Spielstände der \(old)-Fassung. Kopien davon, die diese App schon geholt hat, bleiben auf diesem Mac.")
    }

    // MARK: Aufträge

    func localAPKVariants(for game: Game) -> [LocalAPKVariant] {
        localAPKVariants(for: game.recipe)
    }

    func localAPKVariants(for recipe: Recipe) -> [LocalAPKVariant] {
        _ = localLibraryRevision
        return localVariantStore.variants(for: recipe)
    }

    func autoImportLocalAPK() {
        guard localImportWorker == nil else { return }
        let panel = NSOpenPanel()
        panel.title = "Selecionar APK ou pasta do jogo"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        let manual = localManualRecipeSelection ? localRecipes.first { $0.id == selectedLocalRecipeID } : nil
        localManualRecipeSelection = false
        startLocalImport(source: source, recipe: manual)
    }

    func offerCreateProvisionalAPK() {
        if let path = localImport.apkPath, URL(fileURLWithPath: path).pathExtension.lowercased() == "apk" {
            createProvisionalRecipeFromAPK(URL(fileURLWithPath: path))
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Selecionar APK para receita local provisória"
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let apk = panel.url, apk.pathExtension.lowercased() == "apk" else { return }
        createProvisionalRecipeFromAPK(apk)
    }

    /// The generic import starts from a standalone APK picker and never selects an existing game.
    func importGenericExperimentalAPK() {
        guard !localImport.isRunning else { return }
        let panel = NSOpenPanel()
        panel.title = "Selecionar APK para importação genérica experimental"
        panel.message = "O APK será inspecionado como entrada local independente; receitas e variantes cadastradas não serão substituídas."
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.init(filenameExtension: "apk")!]
        guard panel.runModal() == .OK, let apk = panel.url else { return }
        createProvisionalRecipeFromAPK(apk, allowExistingRecipe: true)
    }

    func associateProvisionalExternalFiles(_ record: LocalProvisionalRecipe) {
        let panel = NSOpenPanel()
        panel.title = "Associar OBB ou arquivos adicionais"
        panel.message = "Os arquivos permanecem no local original. Esta associação registra caminho e tamanho; ainda não comprova conteúdo nem compatibilidade."
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        let accessed = urls.map { ($0, $0.startAccessingSecurityScopedResource()) }
        defer { for (url, active) in accessed where active { url.stopAccessingSecurityScopedResource() } }
        do {
            let updated = try LocalProvisionalRecipeStore(root: DataLocation.base.appendingPathComponent("provisional-recipes", isDirectory: true)).associate(urls, with: record.id)
            if let index = localProvisionalRecipes.firstIndex(where: { $0.id == record.id }) { localProvisionalRecipes[index] = updated }
            localLibraryRevision += 1
        } catch { localImport.message = "Falha ao associar arquivos: \(Self.shortLocalError(error))" }
    }

    func mapProvisionalExternalFile(_ record: LocalProvisionalRecipe, path: String, kind: String,
                                    destination: String, evidence: String) {
        do {
            let store = LocalProvisionalRecipeStore(root: DataLocation.base.appendingPathComponent("provisional-recipes", isDirectory: true))
            let updated = try store.mapExternalFile(path, kind: kind, destination: destination,
                                                    evidence: evidence, for: record.id)
            if let index = localProvisionalRecipes.firstIndex(where: { $0.id == record.id }) {
                localProvisionalRecipes[index] = updated
            }
            localLibraryRevision += 1
        } catch { localImport.message = "Falha ao validar o mapeamento do arquivo: \(Self.shortLocalError(error))" }
    }

    func confirmFunctionalityWithHashChoice(_ receipt: LocalAPKInstallation, variant: LocalAPKVariant, recipe: Recipe) {
        let alert = NSAlert()
        alert.messageText = "Deseja salvar o hash deste APK na receita local?"
        alert.addButton(withTitle: "Salvar hash")
        alert.addButton(withTitle: "Agora não")
        let saveHash = alert.runModal() == .alertFirstButtonReturn
        setFunctionality(receipt, variant: variant, recipe: recipe, confirmed: true, saveHash: saveHash)
    }

    func saveConfirmedHashLater(_ receipt: LocalAPKInstallation, variant: LocalAPKVariant, recipe: Recipe) {
        guard !verifyingLegacyFunctionality.contains(receipt.id) else { return }
        verifyingLegacyFunctionality.insert(receipt.id)
        let registry = localVariantStore
        Task {
            defer { verifyingLegacyFunctionality.remove(receipt.id) }
            do {
                try await Task.detached {
                    try LocalAPKLearningStore(variants: registry).saveVerifiedConfirmedHash(
                        receiptID: receipt.id, variant: variant, recipe: recipe, variants: registry)
                }.value
                localLibraryRevision += 1
            } catch { notice = "\(error)" }
        }
    }

    func localLearning(_ recipe: Recipe) -> LocalAPKLearningRecord? {
        _ = localLibraryRevision
        return try? LocalAPKLearningStore(variants: localVariantStore).load(recipe)
    }

    func localVariantStatus(_ variant: LocalAPKVariant, recipe: Recipe) -> String {
        _ = localLibraryRevision
        do { return try LocalAPKLearningStore(variants: localVariantStore).status(variant, recipe: recipe).rawValue }
        catch { return "Registro local inválido: \(error)" }
    }

    func functionalityInstallations(_ variant: LocalAPKVariant, recipe: Recipe) -> [LocalAPKInstallation] {
        _ = localLibraryRevision
        return (try? LocalAPKLearningStore(variants: localVariantStore).latestInstallations(variant: variant, recipe: recipe)) ?? []
    }

    /// A signing record survives app relaunches. It can expose an install whose pipeline returned before
    /// creating a learning receipt; the button rechecks the live device before recording one.
    func unconfirmedLocalInstallations(_ variant: LocalAPKVariant, recipe: Recipe) -> [UnconfirmedLocalInstallation] {
        _ = localLibraryRevision
        guard let recipeHash = try? LocalAPKBuildEvidence.recipeHash(recipe),
              let assetsHash = try? LocalAPKBuildEvidence.assetsHash(variant) else { return [] }
        guard let learning = try? LocalAPKLearningStore(variants: localVariantStore).load(recipe) else { return [] }
        let gameDirectory = paths.store.directory(for: recipe)
        let signingDirectory = gameDirectory.appendingPathComponent(".signing", isDirectory: true)
        var sources = [gameDirectory.appendingPathComponent(".signing.json")]
        sources += (try? FileManager.default.contentsOfDirectory(at: signingDirectory, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "json" } ?? []
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let canonical: (String?) -> String? = { value in
            guard let value, value.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: value).resolvingSymlinksInPath().standardizedFileURL.path
        }
        var results: [String: UnconfirmedLocalInstallation] = [:]
        for source in sources {
            guard let data = try? Data(contentsOf: source), let signing = try? decoder.decode(SigningRecord.self, from: data),
                  signing.localAPKVariantID == variant.id,
                  canonical(signing.localVariantStorePath) == canonical(localVariantStore.root.path),
                  let bundle = signing.bundleId, SigningRecord.isSafeBundleId(bundle),
                  let request = signing.installedConfiguration,
                  request.localAPKVariantID == variant.id, request.bundleId == bundle,
                  let deviceID = request.device, !deviceID.isEmpty, request.team == signing.team,
                  canonical(signing.toolchainPath) != nil,
                  canonical(signing.toolchainPath) == canonical(request.toolchain),
                  let build = signing.buildEvidence,
                  build.recipeSHA256 == recipeHash,
                  [build.signedBuildSHA256, build.unsignedBuildSHA256].allSatisfy({ $0.count == 64 && $0.allSatisfy(\.isHexDigit) }) else { continue }
            let currentAssetsMatch = build.assetsSHA256 == assetsHash
            let verifiedLegacy = build.assetsSHA256 == nil
                && (try? LegacySigningEvidence.verify(signing: signing, variant: variant, recipe: recipe,
                    variants: localVariantStore, jobs: paths.jobs, store: paths.store, verifyNativeFiles: false)) != nil
            guard currentAssetsMatch || verifiedLegacy else { continue }
            let receiptID = "\(variant.id):\(deviceID):\(bundle):\(signing.installed.timeIntervalSince1970)"
            guard !learning.installations.contains(where: { $0.id == receiptID }) else { continue }
            results[receiptID] = UnconfirmedLocalInstallation(signing: signing)
        }
        return results.values.sorted { $0.signing.installed > $1.signing.installed }
    }

    func confirmUnrecordedLocalInstallation(_ candidate: UnconfirmedLocalInstallation,
                                            variant: LocalAPKVariant, recipe: Recipe) {
        let marker = "install-confirmation:\(candidate.id)"
        guard !verifyingLegacyFunctionality.contains(marker), let request = candidate.signing.installedConfiguration else { return }
        verifyingLegacyFunctionality.insert(marker)
        let registry = localVariantStore, store = paths.store, jobs = paths.jobs
        Task {
            defer { verifyingLegacyFunctionality.remove(marker) }
            do {
                let receipt = try await Task.detached {
                    _ = try LegacySigningEvidence.verify(signing: candidate.signing, variant: variant, recipe: recipe,
                        variants: registry, jobs: jobs, store: store, verifyNativeFiles: true)
                    let installer = Installer(recipe: recipe, request: request, store: store, localVariants: registry,
                                              jobs: jobs, report: { _ in })
                    guard let saved = try installer.recordCurrentLocalInstallation(), saved.id == candidate.id,
                          saved.variantID == variant.id, saved.sha256 == variant.sha256 else {
                        throw LocalAPKVariantError.invalidRecord("A instalação atual não corresponde ao registro de assinatura salvo.")
                    }
                    return saved
                }.value
                localLibraryRevision += 1
                confirmFunctionalityWithHashChoice(receipt, variant: variant, recipe: recipe)
            } catch {
                notice = "Não foi possível verificar a instalação atual: \(error)"
            }
        }
    }

    func localConfirmationPresentation(_ variant: LocalAPKVariant, recipe: Recipe) -> String? {
        _ = localLibraryRevision
        return try? LocalAPKLearningStore(variants: localVariantStore).confirmationPresentation(variant: variant, recipe: recipe)
    }

    func legacyFunctionalityInstallations(_ variant: LocalAPKVariant, recipe: Recipe) -> [LocalAPKInstallation] {
        _ = localLibraryRevision
        return (try? LocalAPKLearningStore(variants: localVariantStore).legacyInstallations(variant: variant, recipe: recipe)) ?? []
    }

    func inspectLegacyFunctionality(_ receipt: LocalAPKInstallation, variant: LocalAPKVariant, recipe: Recipe, retry: Bool = false) {
        guard !verifyingLegacyFunctionality.contains(receipt.id),
              retry || (legacyFunctionalityCandidates[receipt.id] == nil && legacyFunctionalityProblems[receipt.id] == nil) else { return }
        verifyingLegacyFunctionality.insert(receipt.id); legacyFunctionalityProblems[receipt.id] = nil
        let registry = localVariantStore, store = paths.store, jobs = paths.jobs
        Task {
            defer { verifyingLegacyFunctionality.remove(receipt.id) }
            do {
                let recovered = try await Task.detached {
                    try LegacyFunctionalityRecovery.prepare(receipt: receipt, variant: variant, recipe: recipe,
                        variants: registry, store: store, jobs: jobs)
                }.value
                legacyFunctionalityCandidates[receipt.id] = recovered
            } catch {
                legacyFunctionalityCandidates[receipt.id] = nil
                legacyFunctionalityProblems[receipt.id] = "\(error)"
            }
        }
    }

    func setFunctionality(_ receipt: LocalAPKInstallation, variant: LocalAPKVariant, recipe: Recipe, confirmed: Bool, saveHash: Bool = true) {
        if confirmed, receipt.legacyRecovery != nil,
           let original = localLearning(recipe)?.installations.first(where: { $0.id == receipt.id }), original.build == nil {
            guard !verifyingLegacyFunctionality.contains(receipt.id) else { return }
            verifyingLegacyFunctionality.insert(receipt.id)
            let registry = localVariantStore, store = paths.store, jobs = paths.jobs
            Task {
                defer { verifyingLegacyFunctionality.remove(receipt.id) }
                do {
                    try await Task.detached {
                        let fresh = try LegacyFunctionalityRecovery.prepare(receipt: original, variant: variant, recipe: recipe,
                            variants: registry, store: store, jobs: jobs)
                        guard fresh.build == receipt.build, fresh.configuration == receipt.configuration,
                              fresh.legacyRecovery?.sourceHashes == receipt.legacyRecovery?.sourceHashes else {
                            throw LocalAPKVariantError.invalidRecord("Os artefatos mudaram desde a verificação. Verifique novamente antes de confirmar.")
                        }
                        let checked = try registry.validated(id: variant.id, for: recipe, forceFull: true)
                        guard checked.variant == variant, try AndroidAPKSignature.inspect(checked.apk).verified else {
                            throw LocalAPKVariantError.invalidRecord("APK alterado ou assinatura não verificada.")
                        }
                        try LocalAPKLearningStore(variants: registry).confirmRecoveredInstallation(fresh, variant: variant, recipe: recipe, saveConfirmedHash: saveHash)
                    }.value
                    localLibraryRevision += 1
                } catch { notice = "\(error)"; legacyFunctionalityProblems[receipt.id] = "\(error)" }
            }
            return
        }
        guard !verifyingLegacyFunctionality.contains(receipt.id) else { return }
        verifyingLegacyFunctionality.insert(receipt.id)
        let registry = localVariantStore
        Task {
            defer { verifyingLegacyFunctionality.remove(receipt.id) }
            do {
                try await Task.detached {
                    let learning = LocalAPKLearningStore(variants: registry)
                    if confirmed {
                        try learning.confirmVerifiedFunctionality(receiptID: receipt.id, variant: variant, recipe: recipe, variants: registry, saveHash: saveHash)
                    } else {
                        try learning.setFunctionality(receiptID: receipt.id, variant: variant, recipe: recipe, confirmed: false)
                    }
                }.value
                localLibraryRevision += 1
            } catch { notice = "\(error)" }
        }
    }

    func reuseFunctionality(_ receipt: LocalAPKInstallation, variant: LocalAPKVariant, recipe: Recipe) {
        guard !isBusy(recipe.id) else { return }
        let alert = NSAlert()
        alert.messageText = "Instalar com a configuração confirmada?"
        alert.informativeText = "\(recipe.title) · \(receipt.bundleID)\nSHA-256: \(receipt.sha256)\nSerá criado um novo Job com as configurações registradas. Integridade e assinatura serão verificadas normalmente; a nova instalação exigirá nova confirmação de funcionamento."
        alert.addButton(withTitle: "Criar Job de instalação"); alert.addButton(withTitle: "Cancelar")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { _ = try enqueueConfirmedFunctionality(receipt, variant: variant, recipe: recipe) }
        catch { notice = "\(error)" }
    }

    /// Shared with local admission tests. Creates a fresh normal Job, never marks it successful/confirmed.
    @discardableResult
    func enqueueConfirmedFunctionality(_ receipt: LocalAPKInstallation, variant: LocalAPKVariant, recipe: Recipe) throws -> Job {
        guard !isBusy(recipe.id) else { throw JobError.cannotResume("Já existe um Job ativo para este jogo.") }
        var configuration = try LocalAPKLearningStore(variants: localVariantStore).confirmedConfiguration(
            receiptID: receipt.id, variant: variant, recipe: recipe)
        guard let toolchain = toolchain(for: localGame(for: recipe)) else {
            throw LocalAPKVariantError.invalidRecord("A toolchain selecionada está ausente, não verificada ou incompatível. O recibo antigo foi preservado e nenhum Job foi criado.")
        }
        // This is an explicit user action to create a fresh Job. Keep the historical receipt intact and
        // freeze the exact per-game selection without changing the preserved default.
        configuration.toolchain = toolchain.root.path
        configuration.localVariantStorePath = localVariantStore.root.path
        configuration.requireExistingBuildOnResume = nil
        configuration.replaceRunning = nil; configuration.resign = nil
        let job = try paths.jobs.enqueue(Job(recipe: recipe, request: configuration,
            steps: InstallStep.localAPKInstall, toolchainCommit: toolchain.commit()))
        queued.append(job.id); reloadJobs(); selectedJob = job.id; pump()
        return job
    }

    func authorizeLocalVariant(_ variant: LocalAPKVariant, recipe: Recipe) {
        let alert = NSAlert()
        alert.messageText = "Usar este APK local?"
        alert.informativeText = "\(variant.package) · \(variant.versionCode)\nSHA-256: \(variant.sha256)\nSelecionar este arquivo permite as operações locais. Sua integridade será revalidada; autenticidade e funcionamento não estão comprovados. As verificações internas de licença do jogo permanecem ativas."
        alert.addButton(withTitle: "Usar arquivo")
        alert.addButton(withTitle: "Cancelar")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try LocalAPKLearningStore(variants: localVariantStore).authorize(variant, recipe: recipe, allowed: true)
            localLibraryRevision += 1
        } catch { notice = "\(error)" }
    }

    func learnLocalVariant(_ variant: LocalAPKVariant, recipe: Recipe) {
        guard let receipt = localLearning(recipe)?.installations.last(where: { $0.sha256 == variant.sha256 && $0.size == variant.size }) else { return }
        let alert = NSAlert()
        alert.messageText = "Salvar na receita local personalizada?"
        alert.informativeText = "\(variant.size) bytes\nSHA-256: \(variant.sha256)\nBundle ID instalado: \(receipt.bundleID)\nA receita oficial será preservada. Instalação não comprova autenticidade ou licença."
        alert.addButton(withTitle: "Salvar hash e tamanho")
        alert.addButton(withTitle: "Cancelar")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            // Recheck the exact registered APK before committing the confirmed overlay.
            _ = try localVariantStore.validated(id: variant.id, for: recipe, verifyAssetHashes: false)
            try LocalAPKLearningStore(variants: localVariantStore).confirmLearning(variant, recipe: recipe, receiptID: receipt.id)
            localLibraryRevision += 1
        } catch { notice = "\(error)" }
    }

    func restoreLocalLearning(_ revisionID: String?, recipe: Recipe) {
        let alert = NSAlert()
        alert.messageText = "Restaurar configuração local?"
        alert.informativeText = "O histórico, os APKs e os dados instalados serão preservados. Somente a seleção local de hashes será restaurada."
        alert.addButton(withTitle: "Restaurar")
        alert.addButton(withTitle: "Cancelar")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try LocalAPKLearningStore(variants: localVariantStore).restore(revisionID, recipe: recipe)
            localLibraryRevision += 1
        } catch { notice = "\(error)" }
    }

    func chooseLocalVariantDirectory() {
        chooseLocalDirectory(title: L("Choose local variant storage", "Ablage lokaler Varianten auswählen")) { url in
            self.localVariantDirectory = url.path
            self.localLibraryRevision += 1
        }
    }

    func chooseLocalWorkspaceDirectory() {
        chooseLocalDirectory(title: L("Choose local build workspace", "Arbeitsordner für lokale Builds auswählen")) { url in
            self.localWorkspaceDirectory = url.path
        }
    }

    private func chooseLocalDirectory(title: String, selected: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        selected(url.standardizedFileURL)
    }

    func localGame(for recipe: Recipe) -> Game {
        if let game = games.first(where: { $0.id == recipe.id && $0.recipe.versionCode == recipe.versionCode && $0.recipe.source == recipe.source }) { return game }
        return Game(recipe: recipe,
                    status: GameStatus.of(recipe: recipe, store: paths.store, apps: installedApps,
                                          toolchainVersion: paths.toolchain()?.appRevision(target: KleptonRecipeCompatibility.resolve(recipe).toolchain.target) ?? toolchainRevision, bundlePrefix: bundlePrefix))
    }

    func registerLocalAPKVariant(for game: Game) {
        let panel = NSOpenPanel()
        panel.title = L("Import a game folder for \(game.recipe.title)", "Spielordner für \(game.recipe.title) importieren")
        panel.message = L("Choose the game folder on your external drive. AVP Play copies the APK into its local-variants folder and records read-only references to data files; originals are never changed.",
                          "Wähle den Spielordner auf dem externen Laufwerk. AVP Play kopiert die APK nach local-variants und speichert schreibgeschützte Verweise auf Datendateien; Originale werden nie geändert.")
        panel.allowedContentTypes = [.folder]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        importLocalGame(recipe: game.recipe, from: source)
    }

    func importLocalGame(recipe: Recipe, from source: URL, additionalSources: [URL] = [], selectedAPK: URL? = nil, offerInstallation: Bool = false) {
        startLocalImport(source: source, recipe: recipe, additionalSources: additionalSources, selectedAPK: selectedAPK)
    }

    func validateLocalAPKVariant(_ recipe: Recipe, id: String) {
        runLocalOperation(recipe: recipe, id: id, preparing: false)
    }

    func prepareLocalAPKVariant(_ recipe: Recipe, id: String) {
        runLocalOperation(recipe: recipe, id: id, preparing: true)
    }

    func buildLocalAPKVariant(_ game: Game, id: String) {
        if let existing = paths.jobs.all().first(where: {
            $0.recipe.id == game.id && $0.request.localAPKVariantID == id
                && $0.steps == InstallStep.localAPKBuildOnly
                && ($0.state == .waiting || $0.state == .running)
        }) {
            selectedJob = existing.id
            if existing.id != runningJob && !queued.contains(existing.id) {
                section = .jobs
                notice = "Já existe um Build only salvo para esta variante. Escolha um Job existente em Jobs; nenhum duplicado foi criado."
            }
            return
        }
        if xcodeProblem != nil { notice = L("Xcode is missing. “Setup” tells you what to do.", "Xcode fehlt. Unter „Setup“ steht, was zu tun ist."); return }
        guard toolchain(for: game) != nil else { notice = L("The toolchain is not installed yet (see “Setup”).", "Die Toolchain ist noch nicht installiert (siehe „Setup“)."); return }
        enqueue(game, steps: InstallStep.localAPKBuildOnly, show: false, localAPKVariantID: id)
    }

    func installLocalAPKVariant(_ game: Game, id: String) {
        if xcodeProblem != nil { notice = L("Xcode is missing. “Setup” tells you what to do.", "Xcode fehlt. Unter „Einrichtung“ steht, was zu tun ist."); return }
        guard toolchain(for: game) != nil else { notice = L("The toolchain is not installed yet (see “Setup”).", "Die Toolchain ist noch nicht installiert (siehe „Einrichtung“)."); return }
        guard teamValid else { notice = L("The Apple team ID is still missing (see “Setup”).", "Die Apple-Team-ID fehlt noch (siehe „Einrichtung“)."); return }
        guard device != nil else { notice = deviceProblem ?? L("The Vision Pro is not reachable.", "Die Vision Pro ist nicht erreichbar."); return }
        if game.otherSourceInstalled { notice = otherSourceText(game); return }
        if isBusy(game.id) {
            if let existing = jobs.first(where: { $0.recipe.id == game.id && ($0.id == runningJob || queued.contains($0.id) || $0.state == .waiting || $0.state == .running) }) {
                selectedJob = existing.id
                section = .jobs
            }
            return
        }
        startAutomaticLocalInstall(game, variantID: id)
    }

    func install(_ game: Game) {
        guard blocker(for: game) == nil else { return }
        enqueue(game, steps: InstallStep.fullInstall)
    }

    /// Was dem bloßen Laden im Weg steht. Es braucht nur, was mit den Dateien zu tun hat: den Ordner für Downloads,
    /// das Konto, bei dem das Spiel gekauft ist, und Platz. Xcode, Toolchain, Apple-Team und Vision Pro spielen
    /// keine Rolle – wer die noch nicht hat, kann schon laden und später bauen.
    func downloadBlocker(for game: Game) -> String? {
        if let why = storeBlocker { return why }
        if game.draft, !game.prepared {
            return prepareNote[game.id] ?? L("The files of this game have not been looked up yet.", "Die Dateien dieses Spiels sind noch nicht nachgeschlagen.")
        }
        if let why = accountBlocker(for: game) { return why }
        if owned(game) == .no { return notOwnedText(game) }
        if isBusy(game.id) { return L("A job for this game is already running.", "Für dieses Spiel läuft schon ein Auftrag.") }
        if let free = freeBytes, game.status.bytesToDownload + 2_000_000_000 > free {
            return L("Not enough free space on this Mac: \(Installer.gigabytes(game.status.bytesToDownload)) to download, \(Installer.gigabytes(free)) free.",
                     "Auf diesem Mac ist zu wenig Platz: \(Installer.gigabytes(game.status.bytesToDownload)) zu laden, \(Installer.gigabytes(free)) frei.")
        }
        return nil
    }

    /// Ob es für das Spiel etwas gibt, das das Programm selbst laden kann und das noch fehlt. Gezählt werden die
    /// Dateien, nicht ihre Größe: bei einem nachgeschlagenen Spiel aus dem Meta-Store kennt die vorab niemand.
    func hasDownloads(_ game: Game) -> Bool { game.status.filesToDownload > 0 || game.status.bytesToDownload > 0 }

    /// Lädt die Dateien des Spiels, ohne es zu bauen oder zu installieren.
    func download(_ game: Game) {
        guard hasDownloads(game), downloadBlocker(for: game) == nil else { return }
        enqueue(game, steps: InstallStep.download)
    }

    /// Was dem Abgleich der Zusatzinhalte im Weg steht. Anders als eine Installation braucht er kein Xcode und
    /// kein Apple-Team – aber das Spiel muss schon auf dem Gerät sein.
    func syncBlocker(for game: Game) -> String? {
        if let why = storeBlocker { return why }
        if toolchain == nil { return L("The toolchain is not installed yet (see “Setup”).", "Die Toolchain ist noch nicht installiert (siehe „Einrichtung“).") }
        if device == nil { return deviceProblem ?? L("The Vision Pro is not reachable.", "Die Vision Pro ist nicht erreichbar.") }
        if !game.installed { return L("Install the game first – this only adds to a game that is on the Vision Pro.", "Erst das Spiel installieren – das hier ergänzt nur ein Spiel, das schon auf der Vision Pro ist.") }
        if game.needsSteamAccount ? !steamSignedIn : account != .signedIn {
            return game.needsSteamAccount ? L("Sign in to Steam first (see “Setup”).", "Erst bei Steam anmelden (siehe „Einrichtung“).")
                                          : L("For official Meta downloads, sign in under Settings → Official Meta downloads. The Local Library does not need this account.", "Für offizielle Meta-Downloads unter Einstellungen → Offizielle Meta-Downloads anmelden. Die lokale Bibliothek braucht dieses Konto nicht.")
        }
        if owned(game) == .no { return notOwnedText(game) }
        if isBusy(game.id) { return L("A job for this game is already running.", "Für dieses Spiel läuft schon ein Auftrag.") }
        return nil
    }

    /// Fragt Meta neu, welche Zusatzinhalte gekauft sind, lädt die fehlenden und legt sie zum installierten Spiel –
    /// ohne es neu zu bauen.
    func syncAddons(_ game: Game) {
        guard game.recipe.addons != nil, syncBlocker(for: game) == nil else { return }
        enqueue(game, steps: InstallStep.addonSync, addons: true)
    }

    /// Was dem Nachreichen gewählter Inhalte im Weg steht. Wie beim Abgleich der Zusatzinhalte braucht es weder Xcode
    /// noch ein Apple-Team – aber das Spiel muss schon auf dem Gerät sein.
    func extrasBlocker(for game: Game) -> String? {
        if let why = storeBlocker { return why }
        if toolchain == nil { return L("The toolchain is not installed yet (see “Setup”).", "Die Toolchain ist noch nicht installiert (siehe „Einrichtung“).") }
        if device == nil { return deviceProblem ?? L("The Vision Pro is not reachable.", "Die Vision Pro ist nicht erreichbar.") }
        if !game.installed { return L("Install the game first – this only adds to a game that is on the Vision Pro.", "Erst das Spiel installieren – das hier ergänzt nur ein Spiel, das schon auf der Vision Pro ist.") }
        if isBusy(game.id) { return L("A job for this game is already running.", "Für dieses Spiel läuft schon ein Auftrag.") }
        return nil
    }

    /// Löscht eine wählbare Datei aus dem Bestand auf diesem Mac. Auf dem Gerät ändert das nichts.
    func removeFromLibrary(_ file: RecipeFile, of game: Game) {
        guard !isBusy(game.id), !steamBusy.contains(game.id) else { return }
        do {
            try FileManager.default.removeItem(at: paths.store.url(for: file, in: game.recipe))
            notice = L("“\(file.title?.text ?? file.name)” has been removed from this Mac.", "„\(file.title?.text ?? file.name)“ wurde von diesem Mac entfernt.")
        } catch {
            notice = "\(error.localizedDescription)"
        }
        refresh()
    }

    /// Gleicht die wählbaren Inhalte mit dem installierten Spiel ab, ohne es neu zu bauen: Gewähltes, das im Bestand
    /// liegt, wird kopiert; Abgewähltes, das sich vom Gerät nehmen lässt, wird dort geleert.
    func syncExtras(_ game: Game) {
        guard extrasBlocker(for: game) == nil, missingExtras(for: game).isEmpty else { return }
        enqueue(game, steps: InstallStep.contentSync)
    }

    /// - Parameter show: zur Seite „Aufträge“ wechseln und den neuen Auftrag zeigen. Ein Sammelauftrag tut das
    ///   einmal am Ende, nicht für jedes Spiel.
    func enqueue(_ game: Game, steps: [InstallStep], addons: Bool? = nil, show: Bool = true,
                 localAPKVariantID: String? = nil, automaticLocalInstall: Bool = false, freshLocalBuild: Bool = false,
                 replacementConsent: LocalReplacementConsent? = nil, automaticBundleID: String? = nil,
                 automaticDeviceID: String? = nil) {
        if let localAPKVariantID,
           let existing = paths.jobs.all().first(where: {
               $0.recipe.id == game.recipe.id && $0.request.localAPKVariantID == localAPKVariantID
                   && $0.steps == steps && ($0.state == .waiting || $0.state == .running)
           }) {
            selectedJob = existing.id
            if show { section = .jobs }
            notice = "Já existe um Job pendente para esta variante e operação. O Job existente foi preservado."
            return
        }
        if localAPKVariantID != nil, isBusy(game.id) {
            if let existing = jobs.first(where: { $0.recipe.id == game.id && ($0.id == runningJob || queued.contains($0.id) || $0.state == .waiting || $0.state == .running) }) {
                selectedJob = existing.id
                if show { section = .jobs }
            }
            return
        }
        // Nur wer baut oder aufs Gerät kopiert, braucht die Toolchain.
        let downloadOnly = steps == InstallStep.download
        let toolchain = toolchain(for: game)
        guard toolchain != nil || downloadOnly else { return }
        // Ein Entwurf, der ohne Toolchain nachgeschlagen wurde: Jetzt, wo gebaut wird, steht fest, mit welchem Stand.
        var recipe = game.recipe
        if game.draft, recipe.toolchain.minCommit.isEmpty, !downloadOnly, let toolchain {
            recipe = DraftRecipe.retargeted(recipe, target: recipe.toolchain.target, minCommit: toolchain.commit())
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            try? encoder.encode(recipe).write(to: draftsDirectory.appendingPathComponent("\(recipe.id).json"), options: .atomic)
        }
        let requestToolchain = toolchain
        var request = InstallRequest(toolchain: requestToolchain?.root.path ?? "")
        request.localAPKVariantID = localAPKVariantID
        request.localVariantStorePath = localAPKVariantID == nil ? nil : localVariantStore.root.path
        if let localAPKVariantID,
           let variant = localVariantStore.variants(for: recipe).first(where: { $0.id == localAPKVariantID }) {
            request.localAssetsSHA256 = try? LocalAPKBuildEvidence.assetsHash(variant)
        }
        request.localWorkspaceRoot = steps == InstallStep.localAPKBuildOnly ? localWorkspaceRoot.path : nil
        if downloadOnly { request.downloadOnly = true }
        request.team = teamId
        request.device = automaticDeviceID ?? device?.udid
        // Ein Spiel aus Steam: Valves Werkzeug fragt und lädt mit der Anmeldung dieses Kontos.
        if recipe.source == .steam, !steamAccount.isEmpty { request.steamAccount = steamAccount }
        if !game.otherSourceBuilds.isEmpty { request.otherSourceBuilds = game.otherSourceBuilds }
        let chosen = options(for: game)
        request.locales = chosen.locales
        request.optionalNames = chosen.optionalNames
        request.addons = addons ?? chosen.addons
        // Nur eine Installation spielt Spielstände zurück; ein Abgleich von Inhalten rührt sie nicht an.
        if steps.contains(.build) { request.restoreSaves = chosen.restoreSaves ?? true }
        if steps.contains(.build) || steps.contains(.buildOnly) {
            let runtimeOptions = runtimeBuildPreferences.resolve(overrides: RuntimeBuildOverrides(
                surrealSupport: chosen.surrealSupport, controllerMode: chosen.controllerMode,
                frameGeneration: chosen.frameGeneration, surrealSDK: chosen.surrealSDK))
            request.controllerMode = runtimeOptions.controllerMode
            request.surrealSupport = runtimeOptions.surrealSupport
            request.surrealSDK = runtimeOptions.surrealSDK
            request.frameGeneration = runtimeOptions.frameGeneration
            request.coreMods = chosen.coreMods == true
        }
        // Die experimentelle Einstellung gilt für jeden Bau, den dieses Programm anstößt.
        if (steps.contains(.build) || steps.contains(.buildOnly)), experimentalImplementations { request.experimental = true }
        if (steps.contains(.build) || steps.contains(.buildOnly)), metalFXUpscaling {
            request.metalFX = true
            request.resolution = metalFXResolution
        }
        // Die Test-Option des Spiels gilt für jeden Bau – nicht nur für Testkopien.
        if (steps.contains(.build) || steps.contains(.buildOnly)), chosen.xrPrediction == true { request.xrPrediction = true }
        // Ein eigenes Präfix oder das eines kostenlosen Teams: dann steht die Kennung im Auftrag.
        let prefix = bundlePrefix
        if prefix != Toolchain.defaultBundlePrefix() { request.bundleId = "\(prefix).\(game.recipe.toolchain.target)" }
        if let automaticBundleID { request.bundleId = automaticBundleID }
        // Was dieses Programm installiert, ist immer die eigentliche Installation – auch nach einem neuen Präfix.
        request.live = true
        if freshLocalBuild { request.freshLocalBuildID = UUID().uuidString }
        if automaticLocalInstall {
            if request.bundleId == nil {
                request.bundleId = Toolchain.defaultBundleId(target: KleptonRecipeCompatibility.resolve(recipe).toolchain.target)
            }
            request.automaticLocalInstall = true
            request.replacementConsent = replacementConsent
            request.localWorkspaceRoot = localWorkspaceRoot.path
            request.restoreSaves = false
        }
        if !freshLocalBuild, localAPKVariantID != nil, steps == InstallStep.localAPKInstall,
           jobs.contains(where: { $0.state == .finished && $0.steps == [.buildOnly]
               && $0.recipe.id == recipe.id && $0.request.localAPKVariantID == localAPKVariantID }) {
            request.reuseBuildOnly = true
            request.localWorkspaceRoot = localWorkspaceRoot.path
        }
        do {
            if !automaticLocalInstall, let variantID = localAPKVariantID, steps == InstallStep.localAPKInstall,
               let identity = try localBundleIdentity(recipeID: recipe.id, variantID: variantID) {
                try identity.apply(to: &request, target: KleptonRecipeCompatibility.resolve(recipe).toolchain.target)
            }
            // Eingefroren wird der Stand, mit dem der Auftrag beginnt. Seinen Platz in der Reihe bekommt er dabei.
            let proposal = Job(recipe: recipe, request: request, steps: steps, toolchainCommit: toolchain?.commit() ?? "")
            let job = try localAPKVariantID == nil ? paths.jobs.enqueue(proposal) : paths.jobs.admitLocal182(proposal).job
            queued.append(job.id)
            reloadJobs()
            if localAPKVariantID != nil {
                append(job.id, "Validando arquivos do jogo...")
                copyProgress[job.id] = InstallProgress(step: steps.first ?? .buildOnly, done: 0, total: 0,
                    validation: LocalValidationProgress(file: "", index: 0, count: 0, done: 0, total: 0))
            }
            if show {
                selectedJob = job.id
                section = .jobs
            }
            pump()
        } catch {
            notice = "\(error)"
        }
    }

    /// Spiele, für die es eine neuere Fassung gibt und denen nichts im Weg steht.
    /// Gemerkt bis zur nächsten Änderung am Zustand (siehe `derived`).
    var updatable: [Game] {
        if let known = derived.updatable { return known }
        let fresh = games.filter { game in
            // Ein Bau aus einer bearbeiteten Arbeitskopie, die für das Spiel nicht gewählt ist, wird nicht im
            // Sammelauftrag ersetzt: Das entscheidet der Nutzer auf der Seite des Spiels.
            if game.status.builtWith?.modified == true, toolchainChoices.games[game.id] == nil { return false }
            switch game.status.onDevice {
            case .olderToolchain, .olderGame, .unstamped: return blocker(for: game) == nil
            case .current, .notInstalled, .unknown, .otherSource: return false
            }
        }
        derived.updatable = fresh
        return fresh
    }

    /// Legt für jedes aktualisierbare Spiel einen Auftrag an; sie laufen nacheinander.
    func updateAll() {
        let list = updatable
        for game in list { install(game) }
        if let first = list.first, let job = jobs.first(where: { $0.recipe.id == first.id }) { selectedJob = job.id }
    }

    /// Löscht, was dieses Programm für ein Spiel auf dem Mac abgelegt hat. Auf dem Gerät ändert sich nichts.
    func removeFiles(_ game: Game) {
        guard !isBusy(game.id) else { return }
        let directory = paths.store.directory(for: game.recipe)
        notice = L("Removing files …", "Dateien werden entfernt …")
        Task.detached {
            let problem: String?
            do {
                if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
                problem = nil
            } catch {
                problem = "\(error.localizedDescription)"
            }
            await MainActor.run {
                self.notice = problem ?? L("The files of \(game.recipe.title) have been removed from this Mac.",
                                           "Die Dateien von \(game.recipe.title) wurden von diesem Mac entfernt.")
                self.refresh()
            }
        }
    }

    func openProfileSetup(_ request: URL, job: Job) {
        Task {
            do {
                let result = try await Task.detached { () -> (URL, ProfileProvisioning) in
                    let context = try JSONDecoder().decode(ProfileProvisioning.self, from: Data(contentsOf: request))
                    let project = try context.openInXcode(approved: true, root: DataLocation.base.appendingPathComponent("profile-setup"))
                    return (project, context)
                }.value
                resumeMessages[job.id] = "Xcode aberto em \(result.0.path). Use somente Signing & Capabilities e o certificado existente, para o Vision Pro \(result.1.device). Não execute Build/Run nesse projeto. Depois use Resume."
            } catch {
                resumeMessages[job.id] = "Configuração de perfil não concluída: \(error). Build preservado."
            }
        }
    }

    func resume(_ job: Job) {
        selectedJob = job.id; section = .jobs
        guard checkingConnectionJobID == nil else {
            resumeMessages[job.id] = "Aguarde Check Again terminar antes de usar Resume."
            return
        }
        guard job.id != runningJob, !queued.contains(job.id), !resumingJobIDs.contains(job.id) else {
            resumeMessages[job.id] = "Este Job já está em execução, na fila ou verificando a conexão."
            return
        }
        guard !hasActiveEquivalentJobForPresentation(job) else {
            resumeMessages[job.id] = "Outro Job da mesma variante e operação já está ativo. Aguarde antes de iniciar este duplicado preservado."
            return
        }
        resumingJobIDs.insert(job.id)
        let needsDevice = job.remaining.contains(.build) || job.remaining.contains(.stage)
        resumeMessages[job.id] = needsDevice
            ? "Verificando o Job e a conexão atual com o Vision Pro..."
            : "Validando o Job salvo antes de iniciar manualmente..."
        let provider = resumeDevices, paths = paths
        Task { [weak self] in
            let result = await Task.detached { () -> Result<Void, Error> in
                Result {
                    let stored = try paths.jobs.load(job.id)
                    guard stored.state != .finished, stored.state != .cancelled else {
                        throw JobError.cannotResume("Job concluído ou cancelado. Crie outro Job se necessário.")
                    }
                    if !stored.isDownloadOnly {
                        guard stored.toolchainCommit == "cc2856c" else {
                            throw RecipeError.invalid(RuntimePolicy177.blocked)
                        }
                        _ = try RuntimePolicy177.source(at: URL(fileURLWithPath: stored.request.toolchain))
                    }
                    if stored.remaining.contains(.build) || stored.remaining.contains(.stage) {
                        _ = try DeviceControl.select(devices: provider(), udid: stored.request.device)
                    }
                }
            }.value
            guard let self else { return }
            defer { self.resumingJobIDs.remove(job.id) }
            do {
                try result.get()
                _ = try paths.jobs.prepareResume(job.id)
                self.queued.append(job.id)
                self.resumeMessages[job.id] = "Retomada colocada na fila. As etapas concluídas serão preservadas."
                self.append(job.id, "[Retomar] Reconexão verificada; retomando da primeira etapa pendente.")
                self.reloadJobs()
                self.pump()
            } catch {
                let text = "Não foi possível retomar: \(Redaction.redact(String(describing: error)))"
                self.resumeMessages[job.id] = text
                self.notice = text
                self.reloadJobs()
            }
        }
    }

    /// Hält einen Auftrag an. Läuft gerade ein Schritt, endet der Auftrag danach; Downloads brechen sofort ab.
    /// Geladene Dateien und Daten auf dem Gerät bleiben in jedem Fall erhalten.
    func cancel(_ job: Job) {
        if job.id == runningJob {
            stopRequested.insert(job.id)
            localCancellingJobs.insert(job.id)
            runningTask?.cancel()
            append(job.id, copyProgress[job.id]?.validation != nil
                ? L("Cancelamento solicitado; a validação será interrompida entre blocos de leitura.", "Abbruch angefordert; die Dateiprüfung stoppt zwischen Leseblöcken.")
                : L("Cancelamento solicitado; aguardando o encerramento seguro da etapa atual.", "Abbruch angefordert; der laufende Schritt wird sicher beendet."))
        } else {
            queued.removeAll { $0 == job.id }
            _ = try? JobRunner(store: paths.jobs).cancel(job.id)
            closeLog(job.id)
            reloadJobs()
        }
    }

    /// Wie viele Zeilen eines Verlaufs im Speicher bleiben. Gezeigt werden ohnehin nur die letzten (siehe
    /// `LogView`); vollständig steht er in der Datei.
    static let logLinesKept = 1000

    func log(for id: String) -> [String] { logTail(for: id).lines }

    /// Das Ende des Verlaufs eines Auftrags und wie viele Zeilen er insgesamt hat.
    func logTail(for id: String) -> LogTail {
        if let tail = logs[id] { return tail }
        let text = (try? String(contentsOf: paths.logURL(job: id), encoding: .utf8)) ?? ""
        let lines = text.split(separator: "\n")
        return LogTail(lines: lines.suffix(AppModel.logLinesKept).map(String.init), total: lines.count)
    }

    private func append(_ id: String, _ line: String) {
        let clean = Redaction.redact(line)
        var tail = logTail(for: id)
        tail.lines.append(clean)
        tail.total += 1
        // In Schüben kürzen, nicht bei jeder Zeile.
        if tail.lines.count > AppModel.logLinesKept + 200 { tail.lines.removeFirst(tail.lines.count - AppModel.logLinesKept) }
        logs[id] = tail
        // Die Datei bleibt offen, solange der Auftrag läuft (siehe `closeLog`).
        logFiles.write(clean, id: id, to: paths.logURL(job: id))
    }

    /// Schließt die Verlaufsdatei eines Auftrags, falls sie offen ist – am Ende des Laufs, und vorsorglich überall,
    /// wo ein Auftrag aus dem Lauf oder der Liste verschwindet. Mehrfach zu rufen schadet nicht.
    func closeLog(_ id: String) {
        logFiles.close(id)
    }

    /// Beim Beenden des Programms: alle Verlaufsdateien schließen.
    func closeAllLogs() {
        logFiles.closeAll()
    }

    /// Nach einer Zeile, die einen neuen Schritt meldet: nur diesen Auftrag neu lesen, nicht alle.
    private func reloadJob(_ id: String) {
        guard let fresh = try? paths.jobs.load(id), let i = jobs.firstIndex(where: { $0.id == id }) else { return reloadJobs() }
        if jobs[i] != fresh { jobs[i] = fresh }
    }

    /// Es läuft immer nur ein Auftrag: alle bauen im selben Toolchain-Ordner und sprechen dasselbe Gerät an.
    func pump() {
        guard runJobsAutomatically, checkingConnectionJobID == nil, runningTask == nil, preparingLocalVariantIDs.isEmpty, let id = queued.first else { return }
        queued.removeFirst()
        guard let job = try? paths.jobs.load(id) else { closeLog(id); return pump() }
        runningJob = id
        // Der Mac soll nicht einschlafen, während geladen, gebaut oder kopiert wird.
        if awake == nil {
            awake = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .suddenTerminationDisabled],
                                                          reason: "Installing a game on Apple Vision Pro")
        }
        askForNotifications()
        let paths = paths
        let selectedLocalVariantRoot = job.request.localVariantStorePath.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let variants = selectedLocalVariantRoot.map(LocalAPKVariantStore.init(root:)) ?? localVariantStore
        let (lines, feed) = AsyncStream<String>.makeStream()
        let reader = Task { @MainActor in
            for await line in lines {
                self.append(id, line)
                if line.hasPrefix("[") { self.reloadJob(id) }
            }
        }
        let metaTool = Probe.metaToolURL
        runningTask = Task.detached {
            var installer = Installer(recipe: job.recipe, request: job.request, store: paths.store,
                                      localVariants: variants, jobs: paths.jobs, sourceJobID: job.id,
                                      progress: { p in Task { @MainActor in
                                          guard self.runningJob == id else { return }
                                          // Die Verbindungsart kommt einmal am Anfang; die Meldungen danach tragen sie nicht.
                                          var p = p
                                          if p.via == nil { p.via = self.copyProgress[id]?.via }
                                          self.copyProgress[id] = p
                                      } },
                                      report: { feed.yield("    " + $0) })
            installer.metaTool = metaTool
            let now = (try? Toolchain(root: URL(fileURLWithPath: job.request.toolchain)).commit()) ?? "unbekannt"
            do {
                let completedJob = try await JobRunner(store: paths.jobs).run(job, currentToolchain: now, log: { feed.yield($0) }) { step, _ in
                    try Task.checkCancellation()
                    try await installer.perform(step)
                }
                feed.yield(job.request.localAPKVariantID != nil ? completedJob.localCompletion182 : job.steps == [.buildOnly] ? "Build only concluído. O app está no Mac; nenhuma instalação foi realizada." : job.isDownloadOnly
                    ? L("Done: the files of \(job.recipe.title) are on this Mac. Once everything under “Setup” is in place, “Install” builds the game and puts it on the Vision Pro – without downloading again.",
                        "Fertig: Die Dateien von \(job.recipe.title) liegen auf diesem Mac. Sobald unter „Einrichtung“ alles beisammen ist, baut „Installieren“ das Spiel und bringt es auf die Vision Pro – ohne noch einmal zu laden.")
                    : job.isAddonSync
                    ? L("Done: the add-on content of \(job.recipe.title) is up to date. If the game is running, quit it and start it again so that it sees the new content.",
                        "Fertig: Die Zusatzinhalte von \(job.recipe.title) sind auf dem Stand. Läuft das Spiel gerade, beende es und starte es neu, damit es die neuen Inhalte sieht.")
                    : !job.completed.contains(.stage) && !job.steps.contains(.stage)
                    ? "Aplicativo instalado. Transferência dos arquivos ainda não executada; use Etapa 3 na Local Library."
                    : L("Done: \(job.recipe.title) is ready on the device.", "Fertig: \(job.recipe.title) ist auf dem Gerät bereit."))
            } catch is CancellationError {
                feed.yield(L("Stopped.", "Angehalten."))
            } catch {
                feed.yield(L("Stopped: \(error)", "Angehalten: \(error)"))
            }
            feed.finish()
            await reader.value
            if job.steps == [.buildOnly], let completed = try? paths.jobs.load(id), completed.state == .finished {
                await MainActor.run { self.closeLog(id) }
                await self.preserveCompletedLocalBuild(completed)
            }
            await MainActor.run { self.finished(id) }
        }
    }

    private func finished(_ id: String) {
        let cancelled = stopRequested.remove(id) != nil
        localCancellingJobs.remove(id)
        if cancelled { _ = try? JobRunner(store: paths.jobs).cancel(id) }
        closeLog(id)
        localLibraryRevision += 1
        runningTask = nil
        runningJob = nil
        copyProgress[id] = nil
        reloadJobs()
        if !cancelled, let job = try? paths.jobs.load(id) {
            notify(job)
            if job.state == .finished, !job.isDownloadOnly, !job.isAddonSync, !job.steps.contains(.buildOnly) { reportInstall(job.recipe) }
        }
        reportUsage()
        refresh()
        pump()
        removeOlderToolchainsAutomatically()
        if runningJob == nil, let token = awake {
            ProcessInfo.processInfo.endActivity(token)
            awake = nil
        }
    }

    // MARK: Mitteilungen

    /// Mitteilungen gibt es nur für das Programmpaket; ohne Paket (beim Entwickeln) kennt macOS den Absender nicht.
    private var canNotify: Bool { Bundle.main.bundleIdentifier != nil && Snapshot.directory == nil }

    private func askForNotifications() {
        guard canNotify else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Sagt Bescheid, wenn ein Auftrag fertig ist oder hängt – aber nur, wenn das Programm nicht vorn ist.
    private func notify(_ job: Job) {
        guard canNotify, !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = job.recipe.title
        switch job.state {
        case .finished: content.body = job.steps == [.buildOnly] ? "Build only concluído no Mac; nenhuma instalação foi realizada." : job.isDownloadOnly ? L("The files are downloaded.", "Die Dateien sind geladen.")
                                     : job.isAddonSync ? L("Add-on content is up to date.", "Zusatzinhalte sind auf dem Stand.")
                                                       : L("Ready on your Vision Pro.", "Auf deiner Vision Pro bereit.")
        case .failed: content.body = job.isDownloadOnly ? L("The download has stopped and needs your attention.", "Der Download ist angehalten und braucht dich.")
                                                        : L("The installation has stopped and needs your attention.", "Die Installation ist angehalten und braucht dich.")
        default: return
        }
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: job.id, content: content, trigger: nil))
    }
}

/// Wo Rezepte, Bestand, Aufträge und Toolchains liegen.
struct Paths: Sendable {
    let recipes: URL?
    let store: ContentStore
    let jobs: JobStore
    let packager: ToolchainPackager
    /// Die Spielstände: neben dem Ordner für Downloads, wenn einer gewählt ist, sonst bei den Daten des Programms.
    var saves: SaveStore { SaveStore(root: SaveStore.root(forStore: store.root)) }

    init(recipes: URL?, store: ContentStore, jobs: JobStore, packager: ToolchainPackager) {
        self.recipes = recipes; self.store = store; self.jobs = jobs; self.packager = packager
    }

    init() {
        let env = ProcessInfo.processInfo.environment
        func dir(_ key: String) -> URL? { DataLocation.isModified ? nil : DataLocation.directoryOverride(env[key]) }
        store = ContentStore(root: dir("AVPPLAY_STORE") ?? ContentStore.defaultRoot)
        jobs = JobStore(directory: dir("AVPPLAY_JOBS") ?? JobStore.defaultDirectory)
        packager = ToolchainPackager(root: dir("AVPPLAY_TOOLCHAINS") ?? ToolchainPackager.defaultRoot)
        recipes = dir("AVPPLAY_RECIPES") ?? Paths.findRecipes()
    }

    /// Im Programmpaket liegen die Rezepte unter `Resources/recipes`; beim Entwickeln neben dem Quelltext.
    private static func findRecipes() -> URL? {
        let fm = FileManager.default
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("recipes", isDirectory: true),
           fm.fileExists(atPath: bundled.path) { return bundled }
        var starts = [Bundle.main.bundleURL, URL(fileURLWithPath: fm.currentDirectoryPath)]
        // Von Xcode gestartet liegt das Programm in DerivedData und das Arbeitsverzeichnis irgendwo – beides führt
        // nicht zum Quelltext. Der Pfad dieser Datei tut es. Nur in Entwickler-Builds: `#filePath` schreibt den Pfad
        // des bauenden Rechners samt Benutzernamen ins Programm, und in einem Release hat der nichts zu suchen
        // (dort liegen die Rezepte ohnehin im Programmpaket).
        #if DEBUG
        starts.append(URL(fileURLWithPath: #filePath))
        #endif
        for start in starts {
            var dir = start
            for _ in 0..<6 {
                let candidate = dir.appendingPathComponent("recipes", isDirectory: true)
                if fm.fileExists(atPath: candidate.path) { return candidate }
                dir.deleteLastPathComponent()
            }
        }
        return nil
    }

    /// Das neueste installierte Paket; beim Entwickeln ersatzweise das Arbeitsverzeichnis neben den Rezepten.
    func toolchain() -> Toolchain? {
        if let installed = packager.verified850() { return installed }
        return nil
    }

    /// Die Beschreibung, die neben einem Toolchain-Archiv liegt.
    static func manifest(beside archive: URL) -> ToolchainManifest? {
        guard let data = try? Data(contentsOf: ToolchainPackager.sidecar(for: archive)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ToolchainManifest.self, from: data)
    }

    func logURL(job id: String) -> URL {
        try? FileManager.default.createDirectory(at: jobs.directory, withIntermediateDirectories: true)
        return jobs.directory.appendingPathComponent("\(id).log")
    }
}

private extension Array where Element == URL {
    func uniquedByPath() -> [URL] {
        var seen = Set<String>()
        return filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}
