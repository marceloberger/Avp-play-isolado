import XCTest
import SwiftUI
import AppKit
@testable import AVPPlayApp
@testable import AVPPlayCore

final class LocalJobAdmissionTests: XCTestCase {
    @MainActor
    func testAutomaticReplacementCannotQueueUntilConfirmed140() throws {
        let (model,game,root) = try fixture()
        let app = InstalledApp(bundleIdentifier:"fixture.dev.klepton.target.re4",name:"Fixture",version:"1",bundleVersion:"1",url:"file:///app")
        let consent = LocalReplacementConsent(device:"fixture-headset",app:app)
        var request = InstallRequest(toolchain:model.paths.packager.installed().first!.root.path)
        request.localAPKVariantID="fixture";request.automaticLocalInstall=true;request.reuseBuildOnly=true
        request.bundleId=app.bundleIdentifier;request.device="fixture-headset"
        var plan = AutomaticLocalPlan(request:request,replacement:consent,profile:root.appendingPathComponent("fixture.profile"))
        XCTAssertThrowsError(try model.enqueueAutomaticLocalPlan(plan,recipe:game.recipe))
        XCTAssertTrue(model.paths.jobs.all().isEmpty)
        plan.request.replacementConsent=consent
        try model.enqueueAutomaticLocalPlan(plan,recipe:game.recipe)
        let job = try XCTUnwrap(model.paths.jobs.all().first)
        XCTAssertEqual(job.steps,[.fetch,.build,.stage]);XCTAssertEqual(job.request.replacementConsent,consent)
        XCTAssertNil(model.runningJob)
    }

    @MainActor
    func testAutomaticNewLocalInstallQueuesFetchBuildAndStageWithoutReuse() throws {
        let (model, game, _) = try fixture()
        model.teamId = "TESTTEAM01"
        model.device = Device(udid: "fixture-headset", name: "Fixture", osVersion: "27", reachable: true, paired: true, developerMode: true)
        model.enqueue(game, steps: InstallStep.localAPKInstall, localAPKVariantID: "fixture-variant",
            automaticLocalInstall: true, automaticDeviceID: "fixture-headset")
        let job = try XCTUnwrap(model.jobs.first)
        XCTAssertEqual(job.steps, [.fetch, .build, .stage])
        XCTAssertEqual(job.request.automaticLocalInstall, true)
        XCTAssertEqual(job.request.localAPKVariantID, "fixture-variant")
        XCTAssertEqual(job.request.device, "fixture-headset")
        XCTAssertEqual(job.request.restoreSaves, false)
        XCTAssertNil(job.request.reuseBuildOnly)
        XCTAssertNil(job.request.replacementConsent)
        model.cancel(job)
    }

    @MainActor
    func testPersistedSigningRecordSurfacesUnconfirmedInstallationAfterReopen() throws {
        let (model, game, root) = try fixture()
        let oldRoot = model.localVariantDirectory
        defer { model.localVariantDirectory = oldRoot }
        model.localVariantDirectory = root.appendingPathComponent("reopen-library").path
        let registry = model.localVariantStore
        let variant = LocalAPKVariant(id: "reopened-variant", recipeID: game.id,
            recipeVersionCode: game.recipe.versionCode, relativePath: "missing.apk", size: 10,
            sha256: String(repeating: "a", count: 64), package: game.recipe.package,
            versionCode: String(game.recipe.versionCode), architectures: ["arm64-v8a"], source: "local",
            trustStatus: "local-unverified", official: false, recipeValidated: false, registeredAt: Date())
        let bundle = "fixture.dev.klepton.target.re4", device = "fixture-headset", team = "TESTTEAM01"
        var request = InstallRequest(toolchain: model.paths.packager.installed().first!.root.path)
        request.localAPKVariantID = variant.id; request.localVariantStorePath = registry.root.path
        request.bundleId = bundle; request.device = device; request.team = team
        var signing = SigningRecord(team: team, free: true, installed: Date(), expires: nil,
            bundleId: bundle, localAPKVariantID: variant.id, localVariantStorePath: registry.root.path,
            toolchainPath: request.toolchain)
        signing.installedConfiguration = request
        signing.buildEvidence = LocalAPKBuildEvidence(signedBuildSHA256: String(repeating: "b", count: 64),
            unsignedBuildSHA256: String(repeating: "c", count: 64),
            recipeSHA256: try LocalAPKBuildEvidence.recipeHash(game.recipe),
            assetsSHA256: try LocalAPKBuildEvidence.assetsHash(variant), settings: [:])
        signing.save(store: model.paths.store, recipe: game.recipe, live: false)

        let reopened = AppModel(paths: model.paths, runJobsAutomatically: false, resumeDevices: { [] })
        reopened.localVariantDirectory = model.localVariantDirectory
        XCTAssertTrue(reopened.functionalityInstallations(variant, recipe: game.recipe).isEmpty)
        let pending = try XCTUnwrap(reopened.unconfirmedLocalInstallations(variant, recipe: game.recipe).first)
        XCTAssertEqual(pending.signing.bundleId, bundle)
        XCTAssertEqual(pending.signing.localAPKVariantID, variant.id)
        XCTAssertEqual(pending.id, "\(variant.id):\(device):\(bundle):\(pending.signing.installed.timeIntervalSince1970)")
        XCTAssertTrue(reopened.paths.jobs.all().isEmpty, "Opening this action must not create a Job")
    }

    @MainActor
    private func fixture(resumeDevices: @escaping @Sendable () throws -> [Device] = { [] }) throws -> (AppModel, Game, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("job-admission-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let recipes = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("recipes")
        let runtime = try Verified850Fixture.source()
        let paths = Paths(recipes: recipes, store: ContentStore(root: root.appendingPathComponent("store")),
                          jobs: JobStore(directory: root.appendingPathComponent("jobs")),
                          packager: ToolchainPackager(root: runtime.root.deletingLastPathComponent()))
        let model = AppModel(paths: paths, runJobsAutomatically: false, resumeDevices: resumeDevices)
        let recipe = try RecipeStore(directory: recipes).load(id: "store-2637179839719680")
        return (model, model.localGame(for: recipe), root)
    }

    final class DevicesBox: @unchecked Sendable {
        let lock = NSLock()
        var values: [Device] = []
        func get() -> [Device] { lock.lock(); defer { lock.unlock() }; return values }
        func set(_ value: [Device]) { lock.lock(); defer { lock.unlock() }; values = value }
    }

    @MainActor
    func waitForResume(_ model: AppModel, _ id: String) async throws {
        for _ in 0..<100 {
            if !model.resumingJobIDs.contains(id) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Resume preflight did not finish")
    }

    @MainActor
    func testOfflineResumeShowsReasonThenReconnectionQueuesSameJobOnce() async throws {
        let devices = DevicesBox()
        let (model, game, _) = try fixture(resumeDevices: { devices.get() })
        var request = InstallRequest(toolchain: try XCTUnwrap(model.paths.packager.installed().first).root.path)
        request.localAPKVariantID = "fixture"; request.device = "same-headset"
        var job = Job(recipe: game.recipe, request: request, steps: [.fetch, .build, .stage], toolchainCommit: "cc2856c")
        job.state = .failed; job.failureKind = .device; job.failure = "No paired, reachable Vision Pro found."
        job.completed = [.fetch]; job.current = .build
        try model.paths.jobs.save(job); model.reloadJobs()
        model.resume(job); try await waitForResume(model, job.id)
        XCTAssertEqual(try model.paths.jobs.load(job.id).state, .failed)
        XCTAssertTrue(model.queued.isEmpty)
        XCTAssertTrue(model.resumeMessages[job.id]?.contains("Não foi possível") == true)
        devices.set([Device(udid: "same-headset", name: "Fixture", osVersion: "27", reachable: true, paired: true, developerMode: true)])
        for _ in 0..<3 { model.resume(job) }
        try await waitForResume(model, job.id)
        let resumed = try model.paths.jobs.load(job.id)
        XCTAssertEqual(resumed.state, .waiting); XCTAssertEqual(resumed.completed, [.fetch])
        XCTAssertEqual(model.queued.filter { $0 == job.id }.count, 1)
        XCTAssertEqual(model.selectedJob, job.id); XCTAssertEqual(model.section, .jobs)
        XCTAssertEqual(resumed.request.requireExistingBuildOnResume, true)
        model.cancel(resumed)
    }

    @MainActor
    func testResumeMissingJobShowsErrorAndNeverCreatesGhostQueueEntry() async throws {
        let (model, game, _) = try fixture()
        let missing = Job(recipe: game.recipe, request: InstallRequest(toolchain: try Verified850Fixture.source().root.path), steps: [.buildOnly], toolchainCommit: "cc2856c")
        model.resume(missing); try await waitForResume(model, missing.id)
        XCTAssertTrue(model.queued.isEmpty)
        XCTAssertTrue(model.resumeMessages[missing.id]?.contains("Não foi possível") == true)
    }

    @MainActor
    func testBuildOnlyKeepsCardAndQueuesBeforeReadingEvenMissingLocalVariant() async throws {
        let (model, game, _) = try fixture()
        let start = ProcessInfo.processInfo.systemUptime
        model.buildLocalAPKVariant(game, id: "deliberately-missing-variant")
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1.0)
        XCTAssertEqual(model.section, .library, "Keep progress on the local game card")
        let job = try XCTUnwrap(model.jobs.first)
        XCTAssertEqual(model.selectedJob, job.id)
        XCTAssertEqual(job.request.localAPKVariantID, "deliberately-missing-variant")
        XCTAssertNotNil(model.copyProgress[job.id]?.validation)
        XCTAssertTrue(model.log(for: job.id).joined().contains("Validando arquivos do jogo..."))
        // A missing variant must fail inside the background Job, never prevent its presentation.
        XCTAssertEqual(job.state, .waiting)
        model.cancel(job)
        XCTAssertEqual(try model.paths.jobs.load(job.id).state, .cancelled)
    }

    @MainActor
    func testRepeatedClicksKeepExactlyOneQueuedJob() async throws {
        let (model, game, _) = try fixture()
        for _ in 0..<5 { model.buildLocalAPKVariant(game, id: "missing-variant") }
        XCTAssertEqual(model.jobs.count, 1)
        XCTAssertEqual(model.paths.jobs.all().count, 1)
        XCTAssertEqual(model.section, .library, "Keep progress on the local game card")
        model.cancel(try XCTUnwrap(model.jobs.first))
    }

    @MainActor
    func testAutomaticInstallShowsMissingVariantErrorWithoutCreatingGhostJob() async throws {
        let (model, game, _) = try fixture()
        let previousTeam = model.teamId
        defer { model.teamId = previousTeam }
        model.teamId = "TESTTEAM01"
        model.device = Device(udid: "fixture-only", name: "Fixture", osVersion: "27.0", reachable: true, paired: true, developerMode: true)
        let start = ProcessInfo.processInfo.systemUptime
        model.installLocalAPKVariant(game, id: "deliberately-missing-variant")
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1.0)
        XCTAssertEqual(model.section, .library, "Keep progress on the local game card")
        for _ in 0..<100 where model.localOperationDiagnostics[game.id] == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(model.localOperationDiagnostics[game.id]?.contains("ausente") == true)
        XCTAssertTrue(model.jobs.isEmpty)
    }
    @MainActor
    func testReopenedLibraryQueuesSeparateBuildAndInstallJobsFromPersistedVariant() throws {
        let (initial, game, root) = try fixture()
        let previousRoot = initial.localVariantDirectory, previousTeam = initial.teamId
        defer { initial.localVariantDirectory = previousRoot; initial.teamId = previousTeam }
        let registry = root.appendingPathComponent("custom-library")
        let folder = registry.appendingPathComponent("\(game.recipe.id)-\(game.recipe.versionCode)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Admission only: no worker runs. Byte validation is covered by the Core tests with real fixture APKs.
        let digest = String(repeating: "a", count: 64)
        let variant = LocalAPKVariant(id: "persisted-library-variant", recipeID: game.recipe.id,
            recipeVersionCode: game.recipe.versionCode, relativePath: "\(folder.lastPathComponent)/\(digest).apk",
            size: 3, sha256: digest, package: game.recipe.package, versionCode: String(game.recipe.versionCode),
            versionName: game.recipe.versionName, architectures: ["arm64-v8a"], source: "local", trustStatus: "local-unverified",
            official: false, recipeValidated: false, registeredAt: Date())
        try JSONEncoder().encode(variant).write(to: folder.appendingPathComponent(variant.id + ".json"))
        initial.localVariantDirectory = registry.path
        let reopened = AppModel(paths: initial.paths, runJobsAutomatically: false, resumeDevices: { [] })
        XCTAssertEqual(reopened.localVariantDirectory, registry.path)
        let discovered = try XCTUnwrap(reopened.localAPKVariants(for: game.recipe).first)
        XCTAssertEqual(discovered.id, variant.id)
        reopened.buildLocalAPKVariant(game, id: discovered.id)
        let build = try XCTUnwrap(reopened.jobs.first { $0.steps == InstallStep.localAPKBuildOnly })
        XCTAssertEqual(build.request.localAPKVariantID, variant.id)
        XCTAssertEqual(build.request.localVariantStorePath, registry.path)
        reopened.cancel(build)
        reopened.enqueue(game, steps: InstallStep.localAPKInstall, localAPKVariantID: discovered.id)
        let install = try XCTUnwrap(reopened.jobs.first { $0.steps == InstallStep.localAPKInstall })
        XCTAssertEqual(install.request.localAPKVariantID, variant.id)
        XCTAssertEqual(install.request.localVariantStorePath, registry.path)
        let persisted = try JobStore(directory: reopened.paths.jobs.directory).load(install.id)
        XCTAssertEqual(persisted.request.localAPKVariantID, variant.id)
        XCTAssertEqual(persisted.request.localVariantStorePath, registry.path)
        reopened.cancel(install)
    }

    @MainActor
    func testFunctionalityPersistsInReopenedModelAndReuseQueuesNormalUnconfirmedInstallation() async throws {
        let (model, game, root) = try fixture()
        let oldRoot = model.localVariantDirectory
        defer { model.localVariantDirectory = oldRoot }
        model.localVariantDirectory = root.appendingPathComponent("confirmation-library").path
        let variant = LocalAPKVariant(id: "fixture-confirmed", recipeID: game.id, recipeVersionCode: game.recipe.versionCode,
            relativePath: "missing.apk", size: 3, sha256: String(repeating: "a", count: 64), package: game.recipe.package,
            versionCode: String(game.recipe.versionCode), architectures: ["arm64-v8a"], source: "local",
            trustStatus: "local-unverified", official: false, recipeValidated: false, registeredAt: Date())
        let registry = model.localVariantStore
        let store = LocalAPKLearningStore(variants: registry)
        try store.authorize(variant, recipe: game.recipe, allowed: true)
        let toolchain = try XCTUnwrap(model.paths.packager.installed().first { $0.version() == 850 })
        var request = InstallRequest(toolchain: toolchain.root.path)
        request.localAPKVariantID = variant.id; request.bundleId = "test.confirmed"; request.device = "fixture-vision"
        request.team = "TESTTEAM01"; request.controllerMode = .standard; request.roomMeasuring = true
        request.gameLanguage = "pt-BR"; request.metalFX = true; request.resolution = 75
        var receipt = LocalAPKInstallation(id: "completed-fixture", variantID: variant.id, sha256: variant.sha256,
            size: variant.size, package: variant.package, versionCode: variant.versionCode, bundleID: "test.confirmed",
            deviceID: "fixture-vision", team: "TESTTEAM01", toolchain: "850-cc2856c", date: Date())
        receipt.gameTitle = game.recipe.title; receipt.recipeID = game.id; receipt.configuration = request
        receipt.build = LocalAPKBuildEvidence(signedBuildSHA256: String(repeating: "b", count: 64),
            unsignedBuildSHA256: String(repeating: "c", count: 64), recipeSHA256: try LocalAPKBuildEvidence.recipeHash(game.recipe),
            assetsSHA256: try LocalAPKBuildEvidence.assetsHash(variant), settings: ["KLEPTON_TARGET": "re4", "KL_GAME_LANGUAGE": "pt-BR"])
        try store.recordInstallation(receipt, variant: variant, recipe: game.recipe)
        model.setFunctionality(receipt, variant: variant, recipe: game.recipe, confirmed: true)
        while model.verifyingLegacyFunctionality.contains(receipt.id) { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNil(try store.load(game.recipe).installations[0].confirmedAt, "Missing APK must fail confirmation")
        XCTAssertNil(try store.load(game.recipe).current)
        // Seed a persisted confirmation to test reopening/reuse independently of APK validation.
        try store.setFunctionality(receiptID: receipt.id, variant: variant, recipe: game.recipe,
                                   confirmed: true, saveConfirmedHash: true)
        let reopened = AppModel(paths: model.paths, runJobsAutomatically: false, resumeDevices: { [] })
        let saved = try XCTUnwrap(reopened.functionalityInstallations(variant, recipe: game.recipe).first)
        XCTAssertNotNil(saved.functionalityStatus)
        XCTAssertEqual(saved.configuration?.resolution, 75)
        XCTAssertEqual(saved.sha256.count, 64)
        let job = try reopened.enqueueConfirmedFunctionality(saved, variant: variant, recipe: game.recipe)
        XCTAssertEqual(job.steps, InstallStep.localAPKInstall, "Reuse must include validation, build/sign and stage")
        XCTAssertEqual(job.request.gameLanguage, "pt-BR"); XCTAssertEqual(job.request.resolution, 75)
        XCTAssertEqual(job.request.localAPKVariantID, variant.id)
        XCTAssertTrue(job.request.toolchain.contains("850-cc2856c"), "A fresh user-confirmed build is pinned to verified 850; the receipt remains historical.")
        XCTAssertEqual(job.state, .waiting); XCTAssertTrue(job.completed.isEmpty)
        XCTAssertNil(job.request.replaceRunning); XCTAssertNil(job.request.resign)
        XCTAssertThrowsError(try reopened.enqueueConfirmedFunctionality(saved, variant: variant, recipe: game.recipe))
        reopened.cancel(job)
        reopened.setFunctionality(saved, variant: variant, recipe: game.recipe, confirmed: false)
        while reopened.verifyingLegacyFunctionality.contains(saved.id) { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(try store.load(game.recipe).current?.hashes[variant.sha256], variant.size)
        XCTAssertNil(model.functionalityInstallations(variant, recipe: game.recipe).first?.functionalityStatus)
        XCTAssertThrowsError(try reopened.enqueueConfirmedFunctionality(saved, variant: variant, recipe: game.recipe))
        XCTAssertEqual(reopened.paths.jobs.all().count, 1, "Revocation must prevent creating another Job")

        if let preview = ProcessInfo.processInfo.environment["AVPPLAY_FUNCTIONALITY_PREVIEW"] {
            let revoked = try XCTUnwrap(reopened.functionalityInstallations(variant, recipe: game.recipe).first)
            for (name, item) in [("confirmed", saved), ("unconfirmed", receipt), ("revoked", revoked)] {
                let renderer = ImageRenderer(content: FunctionalityReceiptView(receipt: item, variant: variant, recipe: game.recipe)
                    .environmentObject(reopened).padding(20).frame(width: 760).background(Color(nsColor: .windowBackgroundColor)))
                renderer.scale = 2
                let image = try XCTUnwrap(renderer.cgImage)
                let bitmap = NSBitmapImageRep(cgImage: image)
                let url = URL(fileURLWithPath: preview).deletingLastPathComponent().appendingPathComponent(name + "-preview.png")
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
            }
        }
    }

    @MainActor
    func testVerifiedLegacyProposalDoesNotConfirmOrCreateJobsBeforeClick() throws {
        let (model, game, root) = try fixture()
        let previous = model.localVariantDirectory
        defer { model.localVariantDirectory = previous }
        model.localVariantDirectory = root.appendingPathComponent("legacy-library").path
        let variant = LocalAPKVariant(id: "legacy-variant", recipeID: game.id, recipeVersionCode: game.recipe.versionCode,
            relativePath: "unused.apk", size: 3, sha256: String(repeating: "a", count: 64), package: game.recipe.package,
            versionCode: String(game.recipe.versionCode), architectures: ["arm64-v8a"], source: "local",
            trustStatus: "local-unverified", official: false, recipeValidated: false, registeredAt: Date())
        let store = LocalAPKLearningStore(variants: model.localVariantStore)
        try store.authorize(variant, recipe: game.recipe, allowed: true)
        let old = LocalAPKInstallation(id: "old-installation", variantID: variant.id, sha256: variant.sha256, size: variant.size,
            package: variant.package, versionCode: variant.versionCode, bundleID: "test.legacy.re4", deviceID: "fixture-vision",
            team: "TESTTEAM01", toolchain: "750-fixture", date: Date(timeIntervalSince1970: 1792881300))
        try store.recordInstallation(old, variant: variant, recipe: game.recipe)
        var proposal = old
        var configuration = InstallRequest(toolchain: "/fixture")
        configuration.localAPKVariantID = variant.id; configuration.bundleId = old.bundleID
        configuration.team = old.team; configuration.device = old.deviceID
        proposal.configuration = configuration
        proposal.build = LocalAPKBuildEvidence(signedBuildSHA256: String(repeating: "b", count: 64),
            unsignedBuildSHA256: String(repeating: "c", count: 64), recipeSHA256: try LocalAPKBuildEvidence.recipeHash(game.recipe),
            assetsSHA256: try LocalAPKBuildEvidence.assetsHash(variant), settings: ["Info.KLControllerModeDefault": "standard"])
        proposal.legacyRecovery = LegacyFunctionalityEvidence(verifiedAt: Date(), originalReceiptSHA256: "fixture",
            installationJobID: "fixture-install", buildJobID: "fixture-build", unsignedApp: root.appendingPathComponent("unsigned.app"),
            signedApp: root.appendingPathComponent("signed.app"), sourceHashes: [:])
        model.legacyFunctionalityCandidates[old.id] = proposal
        XCTAssertNil(proposal.functionalityStatus)
        XCTAssertEqual(model.legacyFunctionalityInstallations(variant, recipe: game.recipe).count, 1)
        XCTAssertTrue(model.functionalityInstallations(variant, recipe: game.recipe).isEmpty)
        XCTAssertNil(try store.load(game.recipe).installations[0].configuration)
        XCTAssertNil(try store.load(game.recipe).installations[0].confirmedAt)
        XCTAssertTrue(model.paths.jobs.all().isEmpty)
        if let preview = ProcessInfo.processInfo.environment["AVPPLAY_FUNCTIONALITY_PREVIEW"] {
            let renderer = ImageRenderer(content: FunctionalityReceiptView(receipt: proposal, variant: variant, recipe: game.recipe)
                .environmentObject(model).padding(20).frame(width: 760).background(Color(nsColor: .windowBackgroundColor)))
            renderer.scale = 2
            let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
            let output = URL(fileURLWithPath: preview).deletingLastPathComponent().appendingPathComponent("legacy-unconfirmed-preview.png")
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output)
        }
    }

    @MainActor
    func testDataScanIncludesLocalLibraryAndDoesNotRemoveAnyFiles() async throws {
        let (model, game, root) = try fixture()
        let oldRoot = model.localVariantDirectory
        defer { model.localVariantDirectory = oldRoot }
        model.localVariantDirectory = root.appendingPathComponent("data-library").path
        let apk = model.localVariantStore.root.appendingPathComponent("orphan-1/base.apk")
        try FileManager.default.createDirectory(at: apk.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("local-apk".utf8).write(to: apk)
        let job = Job(recipe: game.recipe, request: InstallRequest(toolchain: "/fixture"), steps: [.buildOnly], toolchainCommit: "fixture")
        try model.paths.jobs.save(job)
        model.scanStorage()
        for _ in 0..<300 {
            if !model.storageScanning { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let inventory = try XCTUnwrap(model.storage?.inventory)
        XCTAssertTrue(inventory.entries.contains { $0.url.standardizedFileURL.path == apk.deletingLastPathComponent().path && $0.referencedBytes == 9 })
        XCTAssertEqual(try Data(contentsOf: apk), Data("local-apk".utf8))
        XCTAssertEqual(try model.paths.jobs.load(job.id), job)
        if let preview = ProcessInfo.processInfo.environment["AVPPLAY_STORAGE_PREVIEW"] {
            // GroupBox uses native AppKit drawing; ImageRenderer renders only its title on macOS.
            let hosting = NSHostingView(rootView: StorageInventoryView(inventory: inventory).padding(20).frame(width: 900).background(Color.white).environment(\.colorScheme, .light))
            hosting.setFrameSize(NSSize(width: 900, height: 1600))
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: preview))
        }
    }

    @MainActor
    func testImportCancelAndFailureNeverPublishPrematureSuccessOrCreateJobs() async throws {
        let (model, game, root) = try fixture()
        let oldLibrary = model.localVariantDirectory
        defer { model.localVariantDirectory = oldLibrary }
        model.localVariantDirectory = root.appendingPathComponent("import-library").path
        model.localRecipes = [game.recipe]
        let missing = root.appendingPathComponent("missing.apk")
        model.startLocalImport(source: missing)
        XCTAssertTrue(model.localImport.isRunning)
        XCTAssertNil(model.localImport.message)
        model.startLocalImport(source: root.appendingPathComponent("other.apk"))
        XCTAssertEqual(model.localImport.sourcePath, missing.path, "Prevent duplicate imports")
        model.cancelLocalImport()
        for _ in 0..<300 {
            if !model.localImport.isRunning { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.localImport.isRunning)
        XCTAssertNotEqual(model.localImport.message, "APK importado com sucesso")
        XCTAssertTrue(model.paths.jobs.all().isEmpty)
        XCTAssertTrue(model.localAPKVariants(for: game.recipe).isEmpty)
        // Keep this failure case on the explicit recipe route. Automatic
        // identification may start its own analysis and update presentation.
        model.startLocalImport(source: root, recipe: game.recipe, selectedAPK: missing)
        for _ in 0..<300 {
            if !model.localImport.isRunning { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(model.localImport.message?.hasPrefix("Falha na importação:") == true)
        XCTAssertTrue(model.paths.jobs.all().isEmpty)
    }

    @MainActor
    func testLocalLibraryHasOneGamePerPackageAndCanRenderImportStates() throws {
        let (model, game, root) = try fixture()
        let oldLibrary = model.localVariantDirectory, oldRecipe = model.selectedLocalRecipeID
        defer { model.localVariantDirectory = oldLibrary; model.selectedLocalRecipeID = oldRecipe }
        model.localVariantDirectory = root.appendingPathComponent("preview-library").path
        var duplicate = game.recipe; duplicate.id += "-duplicate"
        model.localRecipes = [game.recipe, duplicate]
        model.selectedLocalRecipeID = game.id
        XCTAssertEqual(model.localLibraryGames.count, 1)
        let apk = root.appendingPathComponent("selected-source.apk")
        try Data("temporary preview only".utf8).write(to: apk)
        let variant = LocalAPKVariant(id: "preview-variant", recipeID: game.id, recipeVersionCode: game.recipe.versionCode,
            relativePath: "preview.apk", size: 22, sha256: String(repeating: "a", count: 64), package: game.recipe.package,
            versionCode: String(game.recipe.versionCode), architectures: ["arm64-v8a"],
            androidSignature: AndroidAPKSignature(state: "verified", detail: "Synthetic UI fixture only"),
            source: "local", trustStatus: "local-unverified", official: false, recipeValidated: false,
            originalAPKSourcePath: apk.path, packageMatchesRecipe: true, versionMatchesRecipe: true,
            officialAPKHashMatchesRecipe: false, missingRequiredFiles: [], registeredAt: Date())
        let folder = model.localVariantStore.root.appendingPathComponent("\(game.id)-\(game.recipe.versionCode)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(variant).write(to: folder.appendingPathComponent("preview-variant.json"))
        if let preview = ProcessInfo.processInfo.environment["AVPPLAY_LIBRARY_PREVIEW"] {
            for running in [false, true] {
                model.localImport = LocalImportPresentation(isRunning: running, sourcePath: apk.path,
                    apkPath: apk.path, recipeID: game.id, variantID: variant.id,
                    message: running ? nil : "APK importado com sucesso",
                    progress: running ? LocalImportProgress(phase: "Verificando APK", done: 8, total: 16) : nil)
                model.importingLocalGameIDs = running ? [game.id] : []
                let hosting = NSHostingView(rootView: LocalLibraryView().environmentObject(model).frame(width: 1050, height: 850).background(Color.white).environment(\.colorScheme, .light))
                hosting.setFrameSize(NSSize(width: 1050, height: 850)); hosting.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                let output = URL(fileURLWithPath: preview).appendingPathComponent(running ? "import-running.png" : "import-complete.png")
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output)
            }
        }
    }

    @MainActor
    func testAdditionalFilesReviewButtonCallbackOpensHashAndDestinationReviewForAPKImport() async throws {
        let (model, game, root) = try fixture()
        model.localRecipes = [game.recipe]
        let apk = root.appendingPathComponent("imported-by-apk-only.apk")
        let pak = root.appendingPathComponent("global_localize_PTBR_P.pak")
        let png = root.appendingPathComponent("br.png")
        try Data("synthetic apk source".utf8).write(to: apk)
        try Data("pak review fixture".utf8).write(to: pak)
        try Data("image review fixture".utf8).write(to: png)
        // An individual APK import has no folderPath unless the source parent is recovered.
        model.localImport = LocalImportPresentation(sourcePath: apk.path, apkPath: apk.path,
            recipeID: game.id, unmatchedFiles: [pak.path, png.path])

        model.includeOptionalLocalFiles() // Exact callback wired to the Local Library review button.
        for _ in 0..<200 {
            if model.localAdditionalReview != nil || model.localAdditionalReviewError != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let review = try XCTUnwrap(model.localAdditionalReview, model.localAdditionalReviewError ?? "Review sheet was not presented")
        XCTAssertEqual(review.sourceRoot.standardizedFileURL, root.standardizedFileURL)
        XCTAssertEqual(Set(review.candidates.map(\.name)), ["global_localize_PTBR_P.pak", "br.png"])
        for item in review.candidates {
            XCTAssertEqual(item.sha256, try Hashing.sha256(of: URL(fileURLWithPath: item.origin)))
            XCTAssertEqual(item.size, ContentStore.fileSize(URL(fileURLWithPath: item.origin)))
            XCTAssertEqual(item.suggestedDestination, "android-files/Android/obb/\(game.recipe.package)/\(item.name)")
        }
        let hosting = NSHostingView(rootView: LocalAdditionalFilesReviewSheet(review: review) { _ in }
            .frame(width: 800, height: 600).environment(\.colorScheme, .light))
        hosting.setFrameSize(NSSize(width: 800, height: 600)); hosting.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        XCTAssertThrowsError(try model.confirmOptionalLocalFiles(review, destinations: [:]))
        let selected = Dictionary(uniqueKeysWithValues: review.candidates.map { ($0.origin, $0.suggestedDestination) })
        try model.confirmOptionalLocalFiles(review, destinations: selected)
        XCTAssertTrue(model.localImport.isRunning, "Confirm starts a normal local import with the selected files")
        for _ in 0..<300 {
            if !model.localImport.isRunning { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.localImport.isRunning)
        XCTAssertTrue(model.localImport.message?.hasPrefix("Falha na importação:") == true,
                      "A synthetic invalid APK failure is surfaced in the Local Library status")
        XCTAssertTrue(model.paths.jobs.all().isEmpty)
    }

    @MainActor
    func testProvisionalRecipeIsSelectableAndCardRendersWithoutEnablingOperations() throws {
        let (model, game, _) = try fixture()
        let record = LocalProvisionalRecipe(apkSHA256: String(repeating: "a", count: 64), apkSize: 100,
            apkPath: "/external/new-game.apk", title: "New Quest Game", package: "com.example.newquest",
            versionName: "1.2", versionCode: "12", architectures: ["arm64-v8a"],
            nativeLibraries: ["lib/arm64-v8a/libgame.so"], assets: ["assets/data.bin"],
            externalFileReferences: [], externalFiles: [], createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        model.localRecipes = [game.recipe]
        model.localProvisionalRecipes = [record]
        model.selectedLocalRecipeID = record.id
        let hosting = NSHostingView(rootView: LocalLibraryView().environmentObject(model).frame(width: 1050, height: 850))
        hosting.setFrameSize(NSSize(width: 1050, height: 850)); hosting.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        XCTAssertEqual(model.selectedLocalRecipeID, record.id)
        XCTAssertTrue(record.compatibilityBlockers.contains("Receita Klepton compatível e target verificados"))
    }

    @MainActor
    func testCompletedBuildOnlyMakesInstallReuseOnly137() throws {
        let (model, game, _) = try fixture()
        let id = "fixture-preserved-variant"
        var request = InstallRequest(toolchain: model.paths.packager.installed().first!.root.path)
        request.localAPKVariantID = id
        var finished = Job(recipe: game.recipe, request: request, steps: [.buildOnly], toolchainCommit: "cc2856c")
        finished.state = .finished; finished.completed = [.buildOnly]
        try model.paths.jobs.save(finished); model.reloadJobs()
        let original = try Data(contentsOf: model.paths.jobs.directory.appendingPathComponent(finished.id + ".json"))
        model.enqueue(game, steps: InstallStep.localAPKInstall, show: false, localAPKVariantID: id)
        let install = try XCTUnwrap(model.jobs.first { $0.steps == InstallStep.localAPKInstall })
        XCTAssertEqual(install.request.reuseBuildOnly, true)
        XCTAssertEqual(install.request.localWorkspaceRoot, model.localWorkspaceRoot.path)
        XCTAssertEqual(try Data(contentsOf: model.paths.jobs.directory.appendingPathComponent(finished.id + ".json")), original)
        XCTAssertNil(model.runningJob)
    }

    @MainActor
    func testFresh187InstallDoesNotDependOnCompletedBuildOnlyOrChangeItsJob() throws {
        let (model, game, _) = try fixture()
        let id = "fresh187-fixture"
        var request = InstallRequest(toolchain: model.paths.packager.installed().first!.root.path)
        request.localAPKVariantID = id
        var previous = Job(recipe: game.recipe, request: request, steps: [.buildOnly], toolchainCommit: "cc2856c")
        previous.state = .finished; previous.completed = [.buildOnly]
        try model.paths.jobs.save(previous); model.reloadJobs()
        let before = try Data(contentsOf: model.paths.jobs.url(previous.id))
        model.enqueue(game, steps: InstallStep.localAPKInstall, show: false,
            localAPKVariantID: id, automaticLocalInstall: true, freshLocalBuild: true)
        let fresh = try XCTUnwrap(model.jobs.first { $0.steps == InstallStep.localAPKInstall })
        XCTAssertNotEqual(fresh.request.reuseBuildOnly, true)
        XCTAssertNotNil(fresh.request.freshLocalBuildID)
        XCTAssertNotNil(fresh.request.bundleId, "Transfer and launch need the actual frozen Bundle ID")
        XCTAssertEqual(fresh.request.automaticLocalInstall, true)
        XCTAssertEqual(fresh.steps, InstallStep.localAPKInstall)
        XCTAssertEqual(try Data(contentsOf: model.paths.jobs.url(previous.id)), before)
        XCTAssertNil(model.runningJob)
    }

    @MainActor
    func testExplicitIdentity139IsVariantScopedAndFrozenWithoutChangingBuildJob() throws {
        let (model, game, _) = try fixture()
        let id = "identity139-fixture-" + UUID().uuidString
        let choice = LocalBundleIdentity(destination: "fixture.dev.klepton.target.re4", source: "fixture.team.dev.klepton.target.re4")
        defer { try? model.saveLocalBundleIdentity(nil, recipe: game.recipe, variantID: id) }
        try model.saveLocalBundleIdentity(choice, recipe: game.recipe, variantID: id)
        XCTAssertEqual(try model.localBundleIdentity(recipeID: game.id, variantID: id), choice)
        XCTAssertNil(try model.localBundleIdentity(recipeID: game.id, variantID: id + "-other"))
        XCTAssertNil(try model.localBundleIdentity(recipeID: "other-game", variantID: id))
        var request = InstallRequest(toolchain: model.paths.packager.installed().first!.root.path)
        request.localAPKVariantID = id; request.bundleId = choice.source
        var job = Job(recipe: game.recipe, request: request, steps: [.buildOnly], toolchainCommit: "cc2856c")
        job.state = .finished; job.completed = [.buildOnly]
        try model.paths.jobs.save(job); model.reloadJobs()
        let before = try Data(contentsOf: model.paths.jobs.url(job.id))
        model.enqueue(game, steps: InstallStep.localAPKInstall, show: false, localAPKVariantID: id)
        let install = try XCTUnwrap(model.jobs.first { $0.steps == InstallStep.localAPKInstall })
        XCTAssertEqual(install.request.bundleId, choice.destination)
        XCTAssertEqual(install.request.preservedBuildBundleID, choice.source)
        XCTAssertEqual(install.request.reuseBuildOnly, true)
        XCTAssertEqual(try Data(contentsOf: model.paths.jobs.url(job.id)), before)
        XCTAssertNil(model.runningJob)
    }

    @MainActor
    func testExplicitIdentity139WithoutCompletedBuildCannotQueueCompilation() throws {
        let (model, game, _) = try fixture()
        let id = "identity139-no-build-" + UUID().uuidString
        defer { try? model.saveLocalBundleIdentity(nil, recipe: game.recipe, variantID: id) }
        try model.saveLocalBundleIdentity(LocalBundleIdentity(destination: "fixture.dev.klepton.target.re4", source: "fixture.team.dev.klepton.target.re4"), recipe: game.recipe, variantID: id)
        model.enqueue(game, steps: InstallStep.localAPKInstall, show: false, localAPKVariantID: id)
        XCTAssertTrue(model.jobs.isEmpty); XCTAssertTrue(model.paths.jobs.all().isEmpty)
        XCTAssertNotNil(model.notice)
    }

}
