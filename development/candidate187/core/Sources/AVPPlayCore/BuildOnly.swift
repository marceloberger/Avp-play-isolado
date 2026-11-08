import Foundation

/// The build-only path is intentionally a separate implementation from Klepton's `run.sh`.
/// It works in a fresh copy so helper scripts that replace generated files cannot touch a
/// toolchain already in use or an earlier build artifact.
public struct BuildOnlyResult: Sendable, Equatable {
    public let workspace: URL
    public let app: URL
    public let log: URL
}

public enum BuildOnlyError: Error, CustomStringConvertible {
    case workspaceExists(URL)
    case commandFailed(String, URL)
    case missingProduct(String)
    case missingArtifact(URL)
    case missingANGLEInputs([URL])
    case missingANGLEFrameworks([URL])

    public var description: String {
        switch self {
        case .workspaceExists(let url): return "Build-only workspace already exists: \(url.path)"
        case .commandFailed(let command, let log): return "Build-only command failed (\(command)); log: \(log.path)"
        case .missingProduct(let target): return "Klepton has no product for target \(target)"
        case .missingArtifact(let url): return "xcodebuild reported success but produced no app at \(url.path)"
        case .missingANGLEInputs(let paths):
            return "Cannot generate ANGLE XCFrameworks: required local binaries are missing, empty or unreadable: \(paths.map(\.path).joined(separator: ", ")). Restore these files from the verified Klepton package; no download or source checkout was attempted."
        case .missingANGLEFrameworks(let paths):
            return "mkangle.sh reported success but did not generate required ANGLE XCFrameworks: \(paths.map(\.path).joined(separator: ", "))"
        }
    }
}

public struct BuildOnlyCommand: Sendable, Equatable {
    public let executable: URL
    public let arguments: [String]
    public let directory: URL
    public let environment: [String: String]

    public init(executable: URL, arguments: [String], directory: URL, environment: [String: String] = [:]) {
        self.executable = executable
        self.arguments = arguments
        self.directory = directory
        self.environment = environment
    }
}

public enum BuildOnlyPipeline {
    /// Commands are explicit and inspectable. This list contains no Klepton run script,
    /// device utility, asset stager, signing registration, or installation command.
    public static func compileCommand(project: URL, product: String, derivedData: URL,
                                      environment: [String: String] = [:]) -> BuildOnlyCommand {
        BuildOnlyCommand(
            executable: URL(fileURLWithPath: "/usr/bin/xcodebuild"),
            arguments: ["-project", project.path, "-scheme", product, "-configuration", "Debug",
                        "-destination", "generic/platform=visionOS", "-derivedDataPath", derivedData.path,
                        "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "CODE_SIGN_IDENTITY=", "build"],
            directory: project.deletingLastPathComponent(),
            environment: environment)
    }

    public static func run(_ command: BuildOnlyCommand, log: URL, aggregateLog: URL? = nil,
                           process: @Sendable (BuildOnlyCommand, URL) throws -> Int32 = runProcessForTesting) throws {
        try Task.checkCancellation()
        guard isSafe(command) else {
            throw RecipeError.invalid("build-only rejected a command that can access a device, stage assets, sign, or install")
        }
        try appendLog("\n[\(ISO8601DateFormatter().string(from: Date()))] \(([command.executable.path] + command.arguments).joined(separator: " "))\nWorking directory: \(command.directory.path)\n", to: log)
        let status: Int32
        do {
            status = try process(command, log)
        } catch {
            try? appendLog("\nLaunch failed: \(Redaction.redact(String(describing: error)))\n", to: log)
            if let aggregateLog { try? appendLog(Data(contentsOf: log), to: aggregateLog) }
            throw error
        }
        try appendLog("\n[exit \(status)]\n", to: log)
        if let aggregateLog { try appendLog(Data(contentsOf: log), to: aggregateLog) }
        try Task.checkCancellation()
        guard status == 0 else {
            throw BuildOnlyError.commandFailed(([command.executable.path] + command.arguments).joined(separator: " "), log)
        }
    }

    private static func appendLog(_ text: String, to log: URL) throws {
        try appendLog(Data(text.utf8), to: log)
    }

    private static func appendLog(_ data: Data, to log: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: log.path) { fm.createFile(atPath: log.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    /// Capture the product name from stdout without discarding Python's stderr or exit status.
    /// stderr goes directly to the log, so a traceback cannot fill an unread pipe and deadlock.
    static func resolveProduct(visionos: URL, target: String, log: URL,
                               environment: [String: String] = [:]) throws -> String {
        try Task.checkCancellation()
        let command = BuildOnlyCommand(executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: [visionos.appendingPathComponent("targets.py").path, target, "product"],
            directory: visionos, environment: environment)
        guard isSafe(command) else { throw RecipeError.invalid("build-only rejected product discovery command") }
        try appendLog("\n[targets.py] \(([command.executable.path] + command.arguments).joined(separator: " "))\nWorking directory: \(visionos.path)\n", to: log)
        let errors = try FileHandle(forWritingTo: log)
        defer { try? errors.close() }
        try errors.seekToEnd()
        let output = Pipe(), process = Process()
        process.executableURL = command.executable
        process.arguments = command.arguments
        process.currentDirectoryURL = visionos
        process.environment = processEnvironment(command)
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch {
            try? appendLog("\nLaunch failed: \(Redaction.redact(String(describing: error)))\n", to: log)
            throw error
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        try CooperativeProcess.wait(process)
        try appendLog(data, to: log)
        try appendLog("\n[exit \(process.terminationStatus)]\n", to: log)
        try Task.checkCancellation()
        guard process.terminationStatus == 0 else {
            throw BuildOnlyError.commandFailed("python3 targets.py \(target) product", log)
        }
        let product = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !product.isEmpty, Recipe.isSafeName(product) else { throw BuildOnlyError.missingProduct(target) }
        return product
    }

    private static func processEnvironment(_ command: BuildOnlyCommand) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in ["KLEPTON_SCOTLAND2","KLEPTON_FRAMEGEN","KLEPTON_SURREAL_SDK","KLEPTON_SURREAL_SUPPORT","SC2_GAME_PROFILE","SC2_BUILD_MODE","SC2_TEST_SET"] { environment[key] = nil }
        environment["KLEPTON_DEVICE"] = nil
        environment["KLEPTON_SIM_UDID"] = nil
        environment[Toolchain.roomMeasuringVariable] = nil
        environment[Toolchain.gameLanguageVariable] = nil
        environment[Toolchain.renderScaleVariable] = nil
        environment["KLEPTON_TEST_ON"] = nil
        return environment.merging(command.environment) { _, new in new }
    }

    /// Distribution packages contain prebuilt ANGLE binaries, not vendor/.git.
    /// Wrap local slices when needed; never fetch or rebuild a source checkout here.
    static func prepareANGLE(workspace: URL, log: URL, environment: [String: String] = [:],
                             process: @Sendable (BuildOnlyCommand, URL) throws -> Int32 = runProcessForTesting) throws {
        let visionos = workspace.appendingPathComponent("visionos", isDirectory: true)
        let frameworks = ["libEGL", "libGLESv2"].map {
            visionos.appendingPathComponent("Frameworks/ANGLE_\($0).xcframework", isDirectory: true)
        }
        func missingFrameworks() -> [URL] {
            frameworks.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true }
        }
        guard !missingFrameworks().isEmpty else { return }
        let inputs = ["xros", "xrsim"].flatMap { platform in
            ["libEGL", "libGLESv2"].map { workspace.appendingPathComponent("vendor/out/\(platform)/\($0).framework/\($0)") }
        }
        let missing = inputs.filter { !FileManager.default.isReadableFile(atPath: $0.path) || (ContentStore.fileSize($0) ?? 0) == 0 }
        guard missing.isEmpty else {
            let error = BuildOnlyError.missingANGLEInputs(missing)
            try appendLog("\nANGLE dependency check failed: \(error)\n", to: log)
            throw error
        }
        try run(BuildOnlyCommand(executable: visionos.appendingPathComponent("mkangle.sh"), arguments: [],
                                 directory: visionos, environment: environment), log: log, process: process)
        let absent = missingFrameworks()
        guard absent.isEmpty else {
            let error = BuildOnlyError.missingANGLEFrameworks(absent)
            try appendLog("\nANGLE output check failed: \(error)\n", to: log)
            throw error
        }
    }

    public static func isSafe(_ command: BuildOnlyCommand) -> Bool {
        let name = command.executable.lastPathComponent
        let allowed = ["make", "mkguest.sh", "mkangle.sh", "mkmvk.sh", "python3", "xcodebuild"]
        guard allowed.contains(name) else { return false }
        let forbidden = ["run.sh", "stage_assets", "devicectl", "simctl", "install", "register"]
        guard !command.environment.keys.contains(where: { ["KLEPTON_DEVICE", "KLEPTON_SIM_UDID"].contains($0) }) else {
            return false
        }
        return !command.arguments.contains { argument in
            let lower = argument.lowercased()
            return forbidden.contains(where: lower.contains)
        }
    }

    /// Copy the toolchain to a never-reused workspace, prepare Klepton's generated inputs
    /// there, then compile the generic visionOS destination. Only this workspace is mutated.
    public static func build(toolchainRoot: URL, recipe: Recipe, store: ContentStore,
                             localAPKVariantID: String? = nil, localVariants: LocalAPKVariantStore = LocalAPKVariantStore(),
                             validateLocalInputs: Bool = true, bundleID: String,
                             appVersion: String, appBuild: String, workspaceRoot: URL,
                             extraEnvironment: [String: String] = [:],
                             process: @Sendable (BuildOnlyCommand, URL) throws -> Int32 = runProcessForTesting) throws -> BuildOnlyResult {
        try Task.checkCancellation()
        _ = try RuntimePolicy177.source(at: toolchainRoot)
        if recipe.localExperimental != nil {
            let supplied = try Toolchain(root: toolchainRoot)
            guard supplied.commit() == "a61188d" || supplied.commit() == "cc2856c" else {
                throw RecipeError.invalid("Receita local experimental exige o runtime Klepton 824 verificado (a61188d); fallback recusado.")
            }
        }
        if validateLocalInputs, let id = localAPKVariantID {
            _ = try localVariants.validatedForPreparation(id: id, for: recipe)
        }
        let recipe = KleptonRecipeCompatibility.resolve(recipe)
        let target = recipe.toolchain.target
        guard Recipe.isSafeName(target), !bundleID.isEmpty else {
            throw RecipeError.invalid("invalid build-only target or bundle identifier")
        }
        let id = UUID().uuidString.lowercased()
        let workspace = workspaceRoot.appendingPathComponent("\(target)-\(id)", isDirectory: true)
        guard !FileManager.default.fileExists(atPath: workspace.path) else { throw BuildOnlyError.workspaceExists(workspace) }
        try FileManager.default.createDirectory(at: workspace.deletingLastPathComponent(), withIntermediateDirectories: true)
        let suppliedRuntime = try Toolchain(root: toolchainRoot)
        if suppliedRuntime.version() == 850 && suppliedRuntime.commit() == "cc2856c" {
            _ = try OptionalRuntime850.verifyFullIntegrity(of: suppliedRuntime)
            try OptionalRuntime850.stageVerifiedPayload(from: suppliedRuntime, to: workspace)
        } else if recipe.localExperimental != nil {
            try OptionalRuntime824.stageVerifiedPayload(from: suppliedRuntime, to: workspace)
            try ExperimentalTLS168.apply(to: workspace)
        } else {
            try FileManager.default.copyItem(at: toolchainRoot, to: workspace)
        }
        if recipe.id == "store-2637179839719680" {
            try KleptonRecipeCompatibility.addResidentEvilTargetMetadata(to: workspace)
        }
        let visionos = workspace.appendingPathComponent("visionos", isDirectory: true)
        try Toolchain(root: workspace).prepare(recipe: recipe, store: store, localAPKVariantID: localAPKVariantID,
                                               localVariants: localVariants, verifyLocalAssetHashes: false,
                                               verifyLocalAPKHash: true)
        try RuntimePolicy177.requireWorkspace(Toolchain(root: workspace))
        let evidence = try RuntimePolicy177.evidence().merging(["Runtime.source": toolchainRoot.path]) { _, new in new }
        try JSONEncoder().encode(evidence).write(to: workspace.appendingPathComponent(".runtime177.json"), options: .withoutOverwriting)
        let log = workspace.appendingPathComponent("build-only.log")
        if suppliedRuntime.version() == 850 && suppliedRuntime.commit() == "cc2856c" {
            try "Runtime efetivo: Klepton 850 cc2856c + TLS168; payload verificado e corrigido em workspace isolado.\n".write(to: log, atomically: true, encoding: .utf8)
        } else if recipe.localExperimental != nil {
            try "Runtime base: Klepton 824 a61188d; overlay experimental TLS168; runtime instalado inalterado.\n".write(to: log, atomically: true, encoding: .utf8)
        }
        let base: [String: String] = [
            "KLEPTON_TARGET": recipe.toolchain.target, "KLEPTON_BUNDLE_ID": bundleID,
            "KLEPTON_APP_VERSION": appVersion, "KLEPTON_APP_BUILD": appBuild,
            "KLEPTON_START_SCREEN": "1", "XROS_PLATFORMS": "xros"
        ].merging(Toolchain.genericEnvironment(recipe: recipe)) { _, new in new }
         .merging(extraEnvironment) { _, new in new }

        func run(_ executable: String, _ args: [String], in directory: URL, env: [String: String] = base) throws {
            try BuildOnlyPipeline.run(BuildOnlyCommand(executable: URL(fileURLWithPath: executable),
                                                       arguments: args, directory: directory, environment: env),
                                      log: log, process: process)
        }
        // These helper operations compile or generate local inputs. They run only in the
        // unique workspace, where their own replacement of generated outputs is contained.
        // A generic target is supplied by environment, so a prebuilt target table may be stale.
        // Generate only inside the fresh workspace, as run.sh does before compiling the runtime.
        try run("/usr/bin/make", ["-s", "targets"], in: workspace)
        try run("/usr/bin/make", ["-s", "build/klepton-ld", "xros", "XROS_PLATFORMS=xros"], in: workspace)
        try run(visionos.appendingPathComponent("mkguest.sh").path, [], in: visionos)
        if base["KLEPTON_SCOTLAND2"] == "1" {
            try run("/usr/bin/python3", [workspace.appendingPathComponent("ports/scotland2/tools/stage_avp_mods.py").path,
                                       "--target", target, "--tree", workspace.appendingPathComponent(target).path], in: workspace)
        }
        try prepareANGLE(workspace: workspace, log: log, environment: base, process: process)
        try run(visionos.appendingPathComponent("mkmvk.sh").path, [], in: visionos)
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        let product = try resolveProduct(visionos: visionos, target: target, log: log, environment: base)
        try run(python.path, [visionos.appendingPathComponent("gen_xcodeproj.py").path], in: visionos)
        let project = visionos.appendingPathComponent("\(product).xcodeproj")
        let derived = visionos.appendingPathComponent("build/avpplay-build-only/\(id)/DerivedData", isDirectory: true)
        let compileLog = workspace.appendingPathComponent("xcodebuild.log")
        let compile = compileCommand(project: project, product: product, derivedData: derived, environment: base)
        try BuildOnlyPipeline.run(compile, log: compileLog, aggregateLog: log, process: process)
        let app = derived.appendingPathComponent("Build/Products/Debug-xros/\(product).app", isDirectory: true)
        guard FileManager.default.fileExists(atPath: app.appendingPathComponent("Info.plist").path) else {
            throw BuildOnlyError.missingArtifact(app)
        }
        return BuildOnlyResult(workspace: workspace, app: app, log: compileLog)
    }

    public static let runProcessForTesting: @Sendable (BuildOnlyCommand, URL) throws -> Int32 = { command, log in
        let fm = FileManager.default
        try fm.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: log.path) { fm.createFile(atPath: log.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        try handle.seekToEnd()
        let process = Process()
        process.executableURL = command.executable
        process.arguments = command.arguments
        process.currentDirectoryURL = command.directory
        // Never inherit a headset or simulator selector from the parent AVP Play process.
        process.environment = processEnvironment(command)
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        try process.run()
        try CooperativeProcess.wait(process)
        return process.terminationStatus
    }
}

public extension Toolchain {
    /// Prepares and compiles a generic visionOS app in an isolated, never-reused workspace.
    /// This method does not call Klepton's run.sh, DeviceControl, stage_assets.sh, devicectl,
    /// signing registration, or any install operation.
    func buildOnly(recipe: Recipe, store: ContentStore, localAPKVariantID: String? = nil,
                   localVariants: LocalAPKVariantStore = LocalAPKVariantStore(),
                   validateLocalInputs: Bool = true, bundleID: String, workspaceRoot: URL, extraEnvironment: [String: String] = [:],
                   process: @Sendable (BuildOnlyCommand, URL) throws -> Int32 = BuildOnlyPipeline.runProcessForTesting) throws -> BuildOnlyResult {
        try BuildOnlyPipeline.build(toolchainRoot: root, recipe: recipe, store: store,
                                    localAPKVariantID: localAPKVariantID, localVariants: localVariants,
                                    validateLocalInputs: validateLocalInputs, bundleID: bundleID,
                                    appVersion: AppStamp.short(versionName: recipe.versionName),
                                    appBuild: AppStamp.build(versionCode: recipe.versionCode,
                                                             toolchainVersion: version(), modified: isModified || (version() == 850 && commit() == "cc2856c"),
                                                             experimental: Toolchain.experimentalSwitches.allSatisfy { extraEnvironment["KLEPTON_TEST_ON", default: ""].contains($0) },
                                                             metalFX: extraEnvironment["KLEPTON_TEST_ON", default: ""].contains(Toolchain.metalFXSwitch),
                                                             resolution: extraEnvironment[Toolchain.renderScaleVariable].flatMap(Double.init).map { Int(($0*100).rounded()) },
                                                             xrPrediction: extraEnvironment["KLEPTON_TEST_ON", default: ""].contains(Toolchain.xrPredictionSwitch),
                                                             coreMods: extraEnvironment["KLEPTON_SCOTLAND2"] == "1"),
                                    workspaceRoot: workspaceRoot, extraEnvironment: extraEnvironment,
                                    process: process)
    }
}
