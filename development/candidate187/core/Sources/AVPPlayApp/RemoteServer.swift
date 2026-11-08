import AppKit
import AVPPlayCore
import Combine
import Network
import SwiftUI

/// Eine gekoppelte Fernbedienung. Ihr Schlüssel liegt im Schlüsselbund, nicht hier.
struct RemotePeer: Codable, Identifiable, Equatable {
    var clientId: String
    var name: String
    var paired: Date
    var lastSeen: Date?
    var id: String { clientId }
}

/// Die gekoppelten Fernbedienungen: Namen und Daten in den Voreinstellungen, die Schlüssel im Schlüsselbund – sie
/// sind so viel wert wie ein Zugang zu diesem Programm.
struct RemotePeerStore {
    static let defaultsKey = "isolatedRemotePeers"
    let keychain = TokenStore(service: "avpplay-candidate187-remote")

    func load() -> [RemotePeer] {
        guard let data = DataLocation.preferences.data(forKey: RemotePeerStore.defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([RemotePeer].self, from: data)) ?? []
    }

    func save(_ peers: [RemotePeer]) {
        DataLocation.preferences.set(try? JSONEncoder().encode(peers), forKey: RemotePeerStore.defaultsKey)
    }

    func key(of clientId: String) -> Data? {
        (try? keychain.read(account: "peer-\(clientId)")).flatMap { RemoteWire.data(hex: $0) }
    }

    func setKey(_ key: Data, of clientId: String) throws {
        try keychain.write(token: RemoteWire.hex(key), account: "peer-\(clientId)")
    }

    func removeKey(of clientId: String) {
        _ = try? keychain.delete(account: "peer-\(clientId)")
    }
}

/// Eine Verbindung einer Fernbedienung.
@MainActor
final class RemoteSession {
    let channel: RemoteChannel
    /// Über den Kopplungsport gekommen: darf nur koppeln.
    let pairing: Bool
    var clientId: String?
    var name = ""
    var welcomed = false
    /// Was zuletzt geschickt wurde – Gleiches geht nicht noch einmal über die Leitung.
    var lastStatus: Data?
    var lastGames: Data?
    /// Die Seiten, die sie gerade zeigt, und was von jeder zuletzt geschickt wurde.
    var panels: Set<String> = []
    var lastPanels: [String: Data] = [:]

    init(channel: RemoteChannel, pairing: Bool) {
        self.channel = channel
        self.pairing = pairing
    }
}

/// Die Fernbedienung von der Vision Pro aus: Der Mac zeigt sich im lokalen Netz (Bonjour) und nimmt Verbindungen
/// der App „AVP Play Remote“ an. Wer sich verbindet, braucht einen Schlüssel – den bekommt er einmal beim Koppeln
/// mit dem Code, der hier in den Einstellungen steht. Gekoppelte Fernbedienungen sehen die Spiele und Aufträge und
/// können installieren, aktualisieren, laden, anhalten und fortsetzen – dasselbe, was die Knöpfe hier tun, mit
/// denselben Prüfungen.
@MainActor
final class RemoteServer: ObservableObject {
    static let enabledKey = "isolatedRemoteControl"
    /// Nach so vielen fehlgeschlagenen Kopplungen gilt ein neuer Code, und eine Minute lang wird nicht gekoppelt.
    static let pairingAttempts = 5
    static let pairingPause: TimeInterval = 60

    @Published private(set) var enabled = DataLocation.preferences.bool(forKey: RemoteServer.enabledKey)
    @Published private(set) var code = RemoteServer.firstCode
    @Published private(set) var peers: [RemotePeer] = []
    /// Kennungen der Fernbedienungen, die gerade verbunden sind.
    @Published private(set) var connected: Set<String> = []
    @Published private(set) var listening = false
    @Published private(set) var problem: String?
    @Published private(set) var pairingPausedUntil: Date?

    let serverId: String = {
        if let id = DataLocation.preferences.string(forKey: "isolatedRemoteServerId") { return id }
        let id = RemoteWire.newId()
        DataLocation.preferences.set(id, forKey: "isolatedRemoteServerId")
        return id
    }()

    private weak var model: AppModel?
    private let store = RemotePeerStore()
    private var keys: [String: Data] = [:]
    private var listener: NWListener?
    private var pairListener: NWListener?
    private var sessions: [ObjectIdentifier: RemoteSession] = [:]
    private let queue = DispatchQueue(label: "io.github.mymartek.avpplay.remote")
    private var watch: AnyCancellable?
    private var pushTask: Task<Void, Never>?
    private var lastGamesAt = Date.distantPast
    private var gamesForced = false
    private var failedPairs = 0
    private let panelCache = RemotePanelCache()
    private var awake: NSObjectProtocol?

    /// Zum Testen mit dem Simulator ein fester Code: `AVPPLAY_REMOTE_CODE=123456` (nur in Debug-Builds).
    private static var firstCode: String {
        #if DEBUG
        if let code = ProcessInfo.processInfo.environment["AVPPLAY_REMOTE_CODE"].flatMap(RemoteWire.normalizedCode) { return code }
        #endif
        return RemoteWire.newCode()
    }

    func attach(_ model: AppModel) {
        if self.model === model, listening { return }
        self.model = model
        guard enabled, Snapshot.directory == nil else { return }
        start()
    }

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        DataLocation.preferences.set(on, forKey: RemoteServer.enabledKey)
        on ? start() : stop()
    }

    /// Der Name, unter dem sich der Mac zeigt.
    var macName: String { Host.current().localizedName ?? ProcessInfo.processInfo.hostName }

    var info: RemoteServerInfo {
        RemoteServerInfo(serverId: serverId, name: macName, appVersion: model?.appVersion ?? "0")
    }

    // MARK: Lauschen

    private func start() {
        problem = nil
        peers = store.load()
        // Die Schlüssel kommen über `security` – nicht auf dem Hauptfaden warten.
        let ids = peers.map(\.clientId)
        let store = store
        Task.detached {
            var found: [String: Data] = [:]
            for id in ids { if let key = store.key(of: id) { found[id] = key } }
            let loaded = found
            await MainActor.run {
                guard self.enabled else { return }
                self.keys = loaded
                // Wessen Schlüssel fehlt, ist nicht mehr gekoppelt.
                if loaded.count != self.peers.count {
                    self.peers.removeAll { loaded[$0.clientId] == nil }
                    store.save(self.peers)
                }
                self.startListener()
                self.startPairListener()
                self.watch = self.model?.objectWillChange.sink { [weak server = self] _ in
                    Task { @MainActor in server?.schedulePush() }
                }
            }
        }
    }

    private func stop() {
        watch = nil
        listener?.cancel(); listener = nil
        pairListener?.cancel(); pairListener = nil
        for session in sessions.values { session.channel.connection.cancel() }
        sessions = [:]
        connected = []
        listening = false
        endAwake()
    }

    /// Der eigentliche Port: nimmt nur, wer einen der Schlüssel der gekoppelten Fernbedienungen hat. Ändert sich
    /// die Menge der Schlüssel, wird er neu aufgemacht; bestehende Verbindungen bleiben.
    private func startListener() {
        listener?.cancel()
        listener = nil
        guard enabled else { return }
        // Ohne gekoppelte Fernbedienung gibt es keinen Schlüssel – dann nimmt der Port einen, den niemand kennt,
        // und zeigt sich trotzdem im Netz, damit die Vision Pro den Mac zum Koppeln findet.
        var psks = keys.map { (identity: RemoteWire.clientIdentity($0.key), key: $0.value) }
        if psks.isEmpty { psks = [(identity: "none", key: RemoteWire.newKey())] }
        let parameters = RemoteWire.parameters(psks: psks)
        parameters.allowLocalEndpointReuse = true
        do {
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: RemoteWire.defaultPort)!)
            var txt = NWTXTRecord()
            txt[RemoteWire.txtServerId] = serverId
            txt[RemoteWire.txtVersion] = "\(RemoteWire.protocolVersion)"
            txt[RemoteWire.txtPairPort] = "\(RemoteWire.pairPort)"
            listener.service = NWListener.Service(name: macName, type: RemoteWire.serviceType, txtRecord: txt)
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { @MainActor in
                    guard let self, let listener, self.listener === listener else { return }
                    switch state {
                    case .ready: self.listening = true; self.problem = nil
                    case .failed(let error):
                        self.listening = false
                        self.problem = L("The remote control cannot listen on port \(RemoteWire.defaultPort): \(error)",
                                         "Die Fernbedienung kann nicht auf Port \(RemoteWire.defaultPort) lauschen: \(error)")
                        // Ein Port, den die vorige Fassung noch hält, wird gleich frei.
                        try? await Task.sleep(for: .seconds(3))
                        if self.listener === listener { self.startListener() }
                    case .cancelled: break
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection, pairing: false) }
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            problem = "\(error)"
        }
    }

    /// Der Kopplungsport: nimmt nur, wer den Code kennt, und dort nichts als das Koppeln.
    private func startPairListener() {
        pairListener?.cancel()
        pairListener = nil
        guard enabled else { return }
        if let until = pairingPausedUntil, until > Date() { return }
        pairingPausedUntil = nil
        let parameters = RemoteWire.parameters(psks: [(identity: RemoteWire.pairIdentity, key: RemoteWire.pairingKey(code: code))])
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters, on: NWEndpoint.Port(rawValue: RemoteWire.pairPort)!) else { return }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection, pairing: true) }
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard case .failed = state else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                guard let self, let listener, self.pairListener === listener else { return }
                self.startPairListener()
            }
        }
        pairListener = listener
        listener.start(queue: queue)
    }

    /// Ein neuer Code; der alte gilt sofort nicht mehr.
    func newCode() {
        code = RemoteWire.newCode()
        failedPairs = 0
        pairingPausedUntil = nil
        startPairListener()
    }

    /// Eine Kopplung ist am Schlüssel gescheitert. Nach einigen davon ein neuer Code und eine Pause – sonst ließe
    /// sich der Code durchprobieren.
    private func pairingFailed() {
        failedPairs += 1
        guard failedPairs >= RemoteServer.pairingAttempts else { return }
        failedPairs = 0
        code = RemoteWire.newCode()
        pairingPausedUntil = Date().addingTimeInterval(RemoteServer.pairingPause)
        pairListener?.cancel()
        pairListener = nil
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(RemoteServer.pairingPause))
            self?.startPairListener()
        }
    }

    func remove(_ peer: RemotePeer) {
        peers.removeAll { $0.clientId == peer.clientId }
        store.save(peers)
        keys[peer.clientId] = nil
        let store = store
        Task.detached { store.removeKey(of: peer.clientId) }
        for session in sessions.values where session.clientId == peer.clientId {
            session.channel.sendAndClose(RemoteServerMessage.refused(L("This remote has been removed on the Mac.", "Diese Fernbedienung wurde auf dem Mac entfernt.")))
        }
        startListener()
    }

    // MARK: Verbindungen

    private func accept(_ connection: NWConnection, pairing: Bool) {
        guard enabled else { return connection.cancel() }
        let channel = RemoteChannel(connection: connection, queue: queue)
        let session = RemoteSession(channel: channel, pairing: pairing)
        let key = ObjectIdentifier(session)
        sessions[key] = session
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .failed(let error):
                    if pairing, case .tls = error { self.pairingFailed() }
                    self.drop(key)
                case .cancelled: self.drop(key)
                default: break
                }
            }
        }
        channel.receive({ [weak self] data in
            Task { @MainActor in self?.received(data, in: key) }
        }, closed: { [weak self] _ in
            Task { @MainActor in
                connection.cancel()
                self?.drop(key)
            }
        })
        connection.start(queue: queue)
    }

    /// Trägt eine Verbindung aus. Ist gerade eine letzte Nachricht unterwegs (`sendAndClose`), endet sie danach.
    private func drop(_ key: ObjectIdentifier, closing: Bool = true) {
        guard let session = sessions.removeValue(forKey: key) else { return }
        if closing { session.channel.connection.cancel() }
        updateConnected()
    }

    private func updateConnected() {
        let now = Set(sessions.values.filter(\.welcomed).compactMap(\.clientId))
        if now != connected { connected = now }
        // Solange eine Fernbedienung verbunden ist, soll macOS das Programm nicht in den Schlummer schicken.
        if now.isEmpty { endAwake() } else if awake == nil {
            awake = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                          reason: "Remote control from Apple Vision Pro")
        }
    }

    private func endAwake() {
        if let awake { ProcessInfo.processInfo.endActivity(awake) }
        awake = nil
    }

    private func received(_ data: Data, in key: ObjectIdentifier) {
        guard let session = sessions[key] else { return }
        guard let message = try? RemoteWire.decoder.decode(RemoteClientMessage.self, from: data) else {
            session.channel.sendAndClose(RemoteServerMessage.refused(L("Unknown message – please update AVP Play Remote.",
                                                               "Unbekannte Nachricht – bitte AVP Play Remote aktualisieren.")))
            return drop(key, closing: false)
        }
        switch message.request {
        case .hello(let hello):
            guard hello.protocolVersion == RemoteWire.protocolVersion else {
                session.channel.sendAndClose(RemoteServerMessage.refused(hello.protocolVersion < RemoteWire.protocolVersion
                    ? L("AVP Play Remote is older than AVP Play on this Mac. Please update it.", "AVP Play Remote ist älter als AVP Play auf diesem Mac. Bitte aktualisiere es.")
                    : L("AVP Play on this Mac is older than AVP Play Remote. Please update AVP Play.", "AVP Play auf diesem Mac ist älter als AVP Play Remote. Bitte aktualisiere AVP Play.")))
                return drop(key, closing: false)
            }
            session.name = hello.name
            if session.pairing { return session.channel.send(RemoteServerMessage.reply(seq: message.seq, error: nil)) }
            // Der Schlüssel hat schon gezeigt, dass die Fernbedienung gekoppelt ist; die Kennung sagt, welche.
            guard let id = hello.clientId, let index = peers.firstIndex(where: { $0.clientId == id }) else {
                session.channel.sendAndClose(RemoteServerMessage.refused(L("This remote is not paired with this Mac any more.",
                                                                   "Diese Fernbedienung ist nicht mehr mit diesem Mac gekoppelt.")))
                return drop(key, closing: false)
            }
            session.clientId = id
            session.welcomed = true
            peers[index].lastSeen = Date()
            if !hello.name.isEmpty { peers[index].name = hello.name }
            store.save(peers)
            updateConnected()
            session.channel.send(RemoteServerMessage.welcome(info))
            session.channel.send(RemoteServerMessage.reply(seq: message.seq, error: nil))
            gamesForced = true
            push()
        case .pair(let name):
            guard session.pairing else { return refuse(session, key) }
            pair(session, name: name, seq: message.seq)
        case .openPanel(let id):
            guard !session.pairing, session.welcomed else { return refuse(session, key) }
            session.panels.insert(id)
            session.lastPanels[id] = nil
            model?.remotePanelOpened(id)
            session.channel.send(RemoteServerMessage.reply(seq: message.seq, error: nil))
            gamesForced = true
            push()
        case .closePanel(let id):
            guard !session.pairing, session.welcomed else { return refuse(session, key) }
            session.panels.remove(id)
            session.lastPanels[id] = nil
            session.channel.send(RemoteServerMessage.reply(seq: message.seq, error: nil))
        default:
            guard !session.pairing, session.welcomed else { return refuse(session, key) }
            if case .cover(let id) = message.request { return sendCover(id, to: session) }
            let error = perform(message.request)
            session.channel.send(RemoteServerMessage.reply(seq: message.seq, error: error))
            gamesForced = true
            schedulePush()
        }
    }

    private func refuse(_ session: RemoteSession, _ key: ObjectIdentifier) {
        session.channel.sendAndClose(RemoteServerMessage.refused(L("Not allowed.", "Nicht erlaubt.")))
        drop(key, closing: false)
    }

    private func pair(_ session: RemoteSession, name: String, seq: Int) {
        let clientId = RemoteWire.newId()
        let key = RemoteWire.newKey()
        let display = name.isEmpty ? "Apple Vision Pro" : String(name.prefix(80))
        let store = store
        Task {
            do {
                try await Task.detached { try store.setKey(key, of: clientId) }.value
            } catch {
                session.channel.send(RemoteServerMessage.reply(seq: seq, error: L("The key could not be stored in the keychain: \(error)",
                                                                                 "Der Schlüssel ließ sich nicht im Schlüsselbund ablegen: \(error)")))
                return
            }
            self.keys[clientId] = key
            self.peers.append(RemotePeer(clientId: clientId, name: display, paired: Date(), lastSeen: nil))
            store.save(self.peers)
            // Ein Code gilt für eine Kopplung.
            self.code = RemoteWire.newCode()
            self.failedPairs = 0
            self.startListener()
            self.startPairListener()
            session.channel.send(RemoteServerMessage.paired(RemotePairing(clientId: clientId, key: key, server: self.info)))
            self.model?.notice = L("“\(display)” is now paired as a remote control.", "„\(display)“ ist jetzt als Fernbedienung gekoppelt.")
        }
    }

    // MARK: Bitten

    /// Führt eine Bitte aus; zurück kommt, was im Weg stand.
    private func perform(_ request: RemoteRequest) -> String? {
        model?.performIsolatedRemote(request) ?? (model == nil ? "AVP Play Isolado is not ready." : nil)
    }

    private func sendCover(_ id: String, to session: RemoteSession) {
        guard let model, let game = model.remoteGames.first(where: { $0.id == id }) else {
            return session.channel.send(RemoteServerMessage.cover(gameId: id, key: nil, jpeg: nil))
        }
        let key = model.remoteCoverKey(game)
        if let own = game.cover {
            return session.channel.send(RemoteServerMessage.cover(gameId: id, key: key, jpeg: RemoteServer.jpeg(own)))
        }
        guard let appId = model.remoteStoreCoverId(game) else {
            return session.channel.send(RemoteServerMessage.cover(gameId: id, key: nil, jpeg: nil))
        }
        let catalogHasOne = game.catalog?.cover == true
        Task {
            let data = await model.covers.image(appId: appId, catalogHasOne: catalogHasOne)
            let jpeg = data.flatMap(NSImage.init(data:)).flatMap { RemoteServer.jpeg($0) }
            session.channel.send(RemoteServerMessage.cover(gameId: id, key: jpeg == nil ? nil : key, jpeg: jpeg))
        }
    }

    /// Ein Titelbild für die Leitung: höchstens 960 Punkte breit, als JPEG.
    static func jpeg(_ image: NSImage, maxWidth: Int = 960) -> Data? {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil), source.width > 0 else { return nil }
        let scale = min(1, Double(maxWidth) / Double(source.width))
        let width = max(1, Int(Double(source.width) * scale)), height = max(1, Int(Double(source.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled).representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }

    // MARK: Stand schicken

    /// Nach einer Änderung am Zustand: gesammelt, höchstens gut zweimal in der Sekunde.
    private func schedulePush() {
        guard pushTask == nil, sessions.values.contains(where: \.welcomed) else { return }
        pushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self else { return }
            self.pushTask = nil
            self.push()
        }
    }

    /// Schickt jeder Fernbedienung, was sich für sie geändert hat. Die Spieleliste ist größer und wird höchstens
    /// alle anderthalb Sekunden neu gebaut – während eines Downloads ändert sich sonst ständig etwas.
    private func push() {
        guard let model else { return }
        let targets = sessions.values.filter(\.welcomed)
        guard !targets.isEmpty else { return }
        let status = try? RemoteWire.encoder.encode(RemoteServerMessage.status(model.remoteStatus()))
        var games: Data?
        var panels: [String: Data] = [:]
        let since = Date().timeIntervalSince(lastGamesAt)
        if gamesForced || since > 1.5 {
            games = try? RemoteWire.encoder.encode(RemoteServerMessage.library(model.remoteLibrary()))
            // Jede Seite einmal, auch wenn mehrere Fernbedienungen sie zeigen.
            for id in Set(targets.flatMap(\.panels)) {
                if let panel = model.remotePanel(id, cache: panelCache) {
                    panels[id] = try? RemoteWire.encoder.encode(RemoteServerMessage.panel(panel))
                }
            }
            lastGamesAt = Date()
            gamesForced = false
        } else {
            // Was jetzt ausgelassen wurde, kommt mit dem nächsten Mal.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.5 - since))
                self?.schedulePush()
            }
        }
        for session in targets {
            if let status, status != session.lastStatus {
                session.channel.send(encoded: status)
                session.lastStatus = status
            }
            if let games, games != session.lastGames {
                session.channel.send(encoded: games)
                session.lastGames = games
            }
            for id in session.panels {
                guard let panel = panels[id], panel != session.lastPanels[id] else { continue }
                session.channel.send(encoded: panel)
                session.lastPanels[id] = panel
            }
        }
    }

    /// Die IPv4-Adressen dieses Macs im lokalen Netz – für die Eingabe von Hand.
    static func addresses() -> [String] {
        var result: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  entry.ifa_flags & UInt32(IFF_UP) != 0, entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let name = String(cString: entry.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                result.append(String(cString: host))
            }
        }
        return result
    }
}

// MARK: Was die Fernbedienung zu sehen bekommt

