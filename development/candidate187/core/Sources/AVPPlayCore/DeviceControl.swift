import Foundation

public struct Device: Sendable, Equatable {
    public let udid: String
    public let name: String
    public let osVersion: String
    public let reachable: Bool
    public let paired: Bool
    public let developerMode: Bool
    /// Worüber der Mac das Headset gerade erreicht; `nil`, wenn `devicectl` dazu nichts sagt.
    public var transport: Transport? = nil
    /// Steht die Verbindung gerade? Ein gekoppeltes Headset ohne stehende Verbindung ist ansprechbar, aber vielleicht
    /// im Ruhezustand: Wer es nur nebenbei fragen will, lässt es dann öfter in Ruhe.
    public var connected = false
    /// CoreDevice UUID, distinct from the hardware UDID accepted by --device.
    public var coreDeviceIdentifier: String? = nil

    /// Der Weg zum Gerät. Apple wählt ihn selbst: Hängt das Headset am Kabel (Developer Strap), läuft alles darüber,
    /// sonst über das WLAN. Vorgeben lässt er sich nicht – aber zeigen.
    public enum Transport: Sendable, Equatable {
        case cable, wifi
        /// Etwas, das diese Fassung nicht kennt, im Wortlaut von `devicectl`.
        case other(String)

        init?(devicectl raw: String?) {
            switch raw {
            case nil, "": return nil
            case "wired": self = .cable
            case "localNetwork": self = .wifi
            case let other?: self = .other(other)
            }
        }

        public var text: String {
            switch self {
            case .cable: return L("USB cable", "USB-Kabel")
            case .wifi: return L("Wi-Fi", "WLAN")
            case .other(let raw): return raw
            }
        }
    }
}

public struct RemoteFile: Sendable, Equatable {
    public let relativePath: String
    public let size: Int64
    public let isDirectory: Bool
    /// Wann die Datei auf dem Gerät zuletzt geändert wurde, soweit das Gerät es sagt.
    public var modified: Date? = nil
}

public struct InstalledApp: Sendable, Equatable {
    public let bundleIdentifier: String
    public let name: String
    public let version: String?
    public let bundleVersion: String?
    /// Wo das Programmpaket auf dem Gerät liegt (als `file://`-Adresse). Daran ist ein laufender Prozess der App zu erkennen.
    public var url: String? = nil
    public var containerAccessible: Bool? = nil
}

public enum DeviceError: Error, CustomStringConvertible {
    case tool(String)
    case fileQuery(RemoteQueryFailure)
    case noDevice
    case ambiguous([String])
    /// Ohne Xcode gibt es `devicectl` nicht – das ist kein Fehler des Geräts.
    case noXcode

    public var description: String {
        switch self {
        case .fileQuery(let failure): return failure.description
        case .tool(let m): return L("devicectl reported an error: \(m)", "devicectl meldet einen Fehler: \(m)")
        case .noXcode:
            return L("The Vision Pro is reached through a tool that comes with Xcode. Install Xcode first.",
                     "Die Vision Pro wird über ein Werkzeug angesprochen, das mit Xcode kommt. Zuerst Xcode installieren.")
        case .noDevice: return L("No paired, reachable Vision Pro found.", "Keine gekoppelte, erreichbare Vision Pro gefunden.")
        case .ambiguous(let names):
            let list = names.joined(separator: ", ")
            return L("Several devices found (\(list)). Please choose one with --device.",
                     "Mehrere Geräte gefunden (\(list)). Bitte mit --device auswählen.")
        }
    }
}

/// Ansteuerung der Vision Pro über Apples `devicectl`. Ausgewertet wird ausschließlich die JSON-Ausgabe.
public struct DeviceControl: Sendable {
    private var query: (@Sendable ([String]) throws -> Data)? = nil
    public init() {}
    /// Test seam: production calls still go through devicectl.
    init(query: @escaping @Sendable ([String]) throws -> Data) { self.query = query }

    // MARK: Auswertung (ohne Gerät testbar)

    static func parseDevices(_ data: Data) throws -> [Device] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any], let entries = result["devices"] as? [[String: Any]] else {
            throw DeviceError.tool("Formato de lista de dispositivos inválido.")
        }
        return entries.compactMap { entry in
            let properties = entry["properties"] as? [String: Any] ?? [:]
            let hardware = properties["hardware"] as? [String: Any] ?? entry["hardwareProperties"] as? [String: Any] ?? [:]
            let connection = properties["connection"] as? [String: Any] ?? entry["connectionProperties"] as? [String: Any] ?? [:]
            let state = properties["state"] as? [String: Any] ?? entry["deviceProperties"] as? [String: Any] ?? [:]
            let software = properties["software"] as? [String: Any] ?? entry["deviceProperties"] as? [String: Any] ?? [:]
            guard hardware["platform"] as? String == "visionOS", hardware["reality"] as? String == "physical",
                  let udid = hardware["udid"] as? String else { return nil }
            let tunnel = connection["state"] as? String ?? connection["tunnelState"] as? String
            let mode = state["developerModeStatus"]
            let enabled = (mode as? String) == "enabled" || (mode as? [String: Any])?["enabled"] != nil
            let os = software["osVersionNumber"] as? String ?? (software["osVersionNumber"] as? [String: Any])?["stringValue"] as? String ?? "?"
            return Device(udid: udid, name: state["name"] as? String ?? "Vision Pro", osVersion: os,
                          reachable: tunnel == "connected" || tunnel == "disconnected",
                          paired: connection["pairingState"] as? String == "paired", developerMode: enabled,
                          transport: Device.Transport(devicectl: connection["transportType"] as? String), connected: tunnel == "connected",
                          coreDeviceIdentifier: entry["identifier"] as? String)
        }
    }

    static func parseFiles(_ data: Data) throws -> [RemoteFile] {
        struct Root: Decodable {
            struct Result: Decodable { let files: [Entry] }
            struct Entry: Decodable {
                struct Meta: Decodable { let size: Int64?; let lastModDate: String? }
                struct Resources: Decodable { let isDirectory: Bool? }
                let relativePath: String?
                let name: String?
                let metadata: Meta?
                let resources: Resources?
            }
            let result: Result
        }
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let outcome = (envelope?["info"] as? [String: Any])?["outcome"] as? String, outcome != "success" {
            throw DeviceError.tool("Listagem inconclusiva: outcome=\(outcome)")
        }
        let entries = try JSONDecoder().decode(Root.self, from: data).result.files
        var seen = Set<String>()
        return try entries.map { e in
            guard let path = e.relativePath ?? e.name, !path.isEmpty,
                  Recipe.isSafeRelativePath(path), seen.insert(path).inserted,
                  let directory = e.resources?.isDirectory,
                  directory || (e.metadata?.size != nil && e.metadata!.size! >= 0) else {
                throw DeviceError.tool("Listagem inconclusiva: entrada sem caminho/tipo/tamanho confiável ou duplicada.")
            }
            return RemoteFile(relativePath: path, size: e.metadata?.size ?? 0, isDirectory: directory,
                              modified: e.metadata?.lastModDate.flatMap { stamp.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) })
        }
    }

    static func parseApps(_ data: Data) throws -> [InstalledApp] {
        struct Root: Decodable {
            struct Result: Decodable { let apps: [Entry] }
            struct Entry: Decodable {
                let bundleIdentifier: String?; let name: String?; let version: String?; let bundleVersion: String?; let url: String?
                let containerAccessible: Bool?
            }
            let result: Result
        }
        return try JSONDecoder().decode(Root.self, from: data).result.apps.compactMap { e in
            guard let id = e.bundleIdentifier else { return nil }
            return InstalledApp(bundleIdentifier: id, name: e.name ?? id, version: e.version, bundleVersion: e.bundleVersion,
                                url: e.url, containerAccessible: e.containerAccessible)
        }
    }

    /// Die Programmdateien aller laufenden Prozesse, als `file://`-Adressen.
    static func parseProcesses(_ data: Data) throws -> [String] {
        struct Root: Decodable {
            struct Result: Decodable { let runningProcesses: [Entry] }
            struct Entry: Decodable { let executable: String? }
            let result: Result
        }
        return try JSONDecoder().decode(Root.self, from: data).result.runningProcesses.compactMap(\.executable)
    }

    /// Läuft die App gerade? Ein Prozess gehört zu ihr, wenn seine Programmdatei in ihrem Programmpaket liegt.
    public static func isRunning(_ app: InstalledApp, executables: [String]) -> Bool {
        guard let url = app.url, !url.isEmpty else { return false }
        let prefix = url.hasSuffix("/") ? url : url + "/"
        return executables.contains { $0.hasPrefix(prefix) }
    }

    // MARK: Aufrufe

    public func devices() throws -> [Device] {
        try DeviceControl.parseDevices(try json(["list", "devices"]))
    }

    /// Die eine Vision Pro, mit der gearbeitet wird: die ausdrücklich genannte, sonst die einzige erreichbare.
    public func pick(udid: String?) throws -> Device {
        try Self.select(devices: devices(), udid: udid)
    }

    public static func select(devices: [Device], udid: String?) throws -> Device {
        let all = devices.filter { $0.paired && $0.reachable }
        if let udid {
            guard let d = all.first(where: { $0.udid == udid }) else { throw DeviceError.noDevice }
            guard d.developerMode else { throw DeviceError.tool("Ative o Modo de Desenvolvimento no Vision Pro selecionado.") }
            return d
        }
        let usable = all.filter(\.reachable)
        guard let first = usable.first else { throw DeviceError.noDevice }
        guard usable.count == 1 else { throw DeviceError.ambiguous(usable.map(\.name)) }
        guard first.developerMode else { throw DeviceError.tool("Ative o Modo de Desenvolvimento no Vision Pro selecionado.") }
        return first
    }

    public func runningExecutables(device: Device) throws -> [String] {
        try DeviceControl.parseProcesses(try json(["device", "info", "processes", "--device", device.udid]))
    }

    public func apps(device: Device) throws -> [InstalledApp] {
        try DeviceControl.parseApps(try json(["device", "info", "apps", "--device", device.udid]))
    }

    /// Exact identity query for staging. A successful empty enumeration is inconclusive,
    /// never proof of uninstall. Retries only read queries; it cannot authorize a transfer itself.
    func installedApp(device: Device, bundle: String, attempts: Int = 3,
                      report: (String) -> Void = { _ in },
                      pause: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) throws -> InstalledApp {
        guard (1...3).contains(attempts) else { throw DeviceError.tool("Número inválido de consultas de identidade") }
        let operation = "device info apps --bundle-id"
        var last = "nenhuma resposta"
        for attempt in 1...attempts {
            try Task.checkCancellation()
            report("Consultando identidade: operação=\(operation), dispositivo=\(device.udid), Bundle ID=\(bundle), tentativa=\(attempt)/\(attempts)")
            do {
                let data = try json(["device", "info", "apps", "--device", device.udid, "--bundle-id", bundle])
                guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let result = root["result"] as? [String: Any],
                      (root["info"] as? [String: Any])?["outcome"] as? String == "success" else {
                    throw DeviceError.tool("Resposta de identidade inconclusiva: resultado/outcome inválido")
                }
                if let expected = device.coreDeviceIdentifier,
                   result["deviceIdentifier"] as? String != expected {
                    throw DeviceError.tool("Resposta de identidade pertence a outro dispositivo ou não informa seu UUID CoreDevice")
                }
                if let matched = result["matchingBundleIdentifier"] as? String, matched != bundle {
                    throw DeviceError.tool("Bundle ID do filtro retornado diverge do solicitado: \(matched)")
                }
                guard let rawApps = result["apps"] as? [[String: Any]], rawApps.count == 1 else {
                    let count = (result["apps"] as? [Any])?.count
                    throw DeviceError.tool("Consulta de identidade inconclusiva: apps=\(count.map(String.init) ?? "formato inválido"); lista vazia não comprova ausência")
                }
                let apps = try Self.parseApps(data)
                let matching = apps.filter { $0.bundleIdentifier == bundle }
                guard apps.count == 1, matching.count == 1, let app = matching.first else {
                    throw DeviceError.tool("Consulta de identidade inconclusiva: apps=\(apps.count), correspondências exatas=\(matching.count); lista vazia não comprova ausência")
                }
                guard let identity = app.url, let url = URL(string: identity), url.isFileURL,
                      !url.path.isEmpty else {
                    throw DeviceError.tool("Identidade retornada sem URL de instalação válida")
                }
                guard app.containerAccessible == true else {
                    throw DeviceError.tool("Acesso ao container da instalação não confirmado pelo CoreDevice")
                }
                report("Identidade consultada: Bundle ID=\(app.bundleIdentifier), URL=\(identity), container acessível")
                return app
            } catch is CancellationError { throw CancellationError() }
            catch {
                last = String(describing: error)
                report("Consulta de identidade interrompida: \(last)")
                if attempt < attempts { pause(Double(attempt)) }
            }
        }
        throw DeviceError.tool("Identidade inconclusiva após \(attempts) consultas somente leitura: operação=\(operation), dispositivo=\(device.udid), Bundle ID=\(bundle). Nenhuma cópia autorizada; recibos preservados. Causa: \(last)")
    }

    public func launch(bundle: String, device: Device) throws {
        guard SigningRecord.isSafeBundleId(bundle) else { throw DeviceError.tool("Bundle ID inválido para execução.") }
        try Task.checkCancellation()
        let data = try json(["device", "process", "launch", "--device", device.udid,
                             "--environment-variables", "{}", bundle])
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["info"] as? [String: Any])?["outcome"] as? String == "success" else {
            throw DeviceError.tool("O Vision Pro não confirmou a execução. Confira a conexão e tente novamente.")
        }
    }

    public func install(_ app: URL, device: Device) throws {
        _ = try run(["device", "install", "app", "--device", device.udid, app.path])
    }

    /// Empty and absent are distinct in `listing`; callers needing only files may use this projection.
    /// Communication errors and inconclusive results always throw.
    public func files(device: Device, bundle: String, subdirectory: String, recursive: Bool = false) throws -> [RemoteFile] {
        try listing(device: device, bundle: bundle, subdirectory: subdirectory, recursive: recursive).files
    }

    public func checkedFiles(device: Device, bundle: String, subdirectory: String) throws -> [RemoteFile] {
        try files(device: device, bundle: bundle, subdirectory: subdirectory)
    }

    func listing(device: Device, bundle: String, subdirectory: String, recursive: Bool = false) throws -> RemoteListing {
        let operation = recursive ? "device info files --recurse" : "device info files --no-recurse"
        func read(_ path: String, recurse: Bool) throws -> [RemoteFile] {
            let data = try json(["device", "info", "files", "--device", device.udid,
                "--domain-type", "appDataContainer", "--domain-identifier", bundle,
                "--subdirectory", path, recurse ? "--recurse" : "--no-recurse"])
            let files = try Self.parseFiles(data)
            // Nonrecursive responses must contain direct children only. Never silently omit an entry.
            guard recurse || files.allSatisfy({ !$0.relativePath.contains("/") }) else {
                throw DeviceError.tool("Listagem inconclusiva: resposta não corresponde ao diretório solicitado.")
            }
            return files
        }
        func resolve(_ path: String, recurse: Bool) throws -> RemoteListing {
            do { return .present(try RemoteReadRetry182.run(pause: { delay in
                if query == nil { Thread.sleep(forTimeInterval: delay) }
            }) { try read(path, recurse: recurse) }) }
            catch {
                let original = error
                // A textual ENOENT alone is insufficient: it may refer to a local tool/service.
                // Confirm absence by listing an ancestor successfully in this same container.
                if RemoteQueryFailure.isMissingCandidate(error), !path.isEmpty, path != "." {
                    let parent = (path as NSString).deletingLastPathComponent
                    let name = (path as NSString).lastPathComponent
                    do {
                        switch try resolve(parent, recurse: false) {
                        case .missingDirectory: return .missingDirectory
                        case .present(let siblings):
                            if !siblings.contains(where: { $0.relativePath == name }) { return .missingDirectory }
                        }
                    } catch {
                        // Keep the requested path in the diagnostic even when its ancestor query fails.
                        throw DeviceError.fileQuery(RemoteQueryFailure(operation: operation, device: device.udid,
                            bundle: bundle, path: path, underlying: original))
                    }
                }
                throw DeviceError.fileQuery(RemoteQueryFailure(operation: operation, device: device.udid,
                    bundle: bundle, path: path, underlying: original))
            }
        }
        return try resolve(subdirectory, recurse: recursive)
    }

    public func copy(_ local: URL, to device: Device, bundle: String, destination: String) throws {
        _ = try run(["device", "copy", "to", "--device", device.udid, "--domain-type", "appDataContainer",
                     "--domain-identifier", bundle, "--source", local.path, "--destination", destination])
    }

    /// Holt eine Datei aus dem Datencontainer der App auf den Mac. Auf dem Gerät ändert das nichts.
    public func copy(from device: Device, bundle: String, source: String, to local: URL) throws {
        try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            _ = try run(["device", "copy", "from", "--device", device.udid, "--domain-type", "appDataContainer",
                         "--domain-identifier", bundle, "--source", source, "--destination", local.path])
        } catch {
            throw DeviceError.fileQuery(RemoteQueryFailure(operation: "device copy from", device: device.udid,
                bundle: bundle, path: source, underlying: error))
        }
    }

    private func json(_ args: [String]) throws -> Data {
        if let query { return try query(args) }
        let out = DataLocation.temporaryDirectory.appendingPathComponent("qi-devicectl-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: out) }
        _ = try run(["--timeout", "30"] + args + ["--json-output", out.path])
        return try Data(contentsOf: out)
    }

    @discardableResult
    private func run(_ args: [String]) throws -> String {
        guard DeveloperTools.present else { throw DeviceError.noXcode }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = ["devicectl"] + args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let errText = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw DeviceError.tool(String((errText.isEmpty ? text : errText).suffix(12000)).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return text
    }
}
