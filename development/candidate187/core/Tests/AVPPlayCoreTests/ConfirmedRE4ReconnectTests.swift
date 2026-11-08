import XCTest
@testable import AVPPlayCore

final class ConfirmedRE4ReconnectTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AVPPLAY_VALIDATE_PERSONAL_STATE"] == "1",
            "Personal RE4 recovery may write Jobs/build receipts; explicit opt-in required")
    }
    func testExistingConfirmedRE4ReceiptMatchesReassociatedVariantAndConfiguration() throws {
        let base = DataLocation.defaultBase(bundleIdentifier: DataLocation.modifiedBundleIdentifier,
                                            support: DataLocation.applicationSupport)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let recipe = try RecipeStore(directory: repo.appendingPathComponent("recipes"))
            .load(id: "store-2637179839719680")
        let variants = LocalAPKVariantStore(root: base.appendingPathComponent("local-variants"))
        let variant = try XCTUnwrap(variants.variants(for: recipe).first {
            $0.id == "store-2637179839719680-203-46efcabd484e"
        })
        XCTAssertEqual(variant.sha256, "46efcabd484e96891c70613694e7504b6fb81c410b724cfb67e78b1c16cece2a")
        XCTAssertTrue(variant.androidSignature?.verified == true)
        XCTAssertEqual(variant.versionMatchesRecipe, true)
        XCTAssertEqual(variant.missingRequiredFiles, [])
        XCTAssertNoThrow(try LocalAPKVariantStore.requireCompatibleDependencies(variant, recipe: recipe))
        XCTAssertEqual(Set(variant.assets?.map(\.name) ?? []), [
            "patch.203.com.Armature.VR4.obb", "main.203.com.Armature.VR4.obb"
        ])

        let learning = LocalAPKLearningStore(variants: variants)
        let record = try learning.load(recipe)
        XCTAssertTrue(record.authorizedHashes.contains(variant.sha256))
        XCTAssertEqual(record.current?.hashes[variant.sha256], variant.size)
        let receipt = try XCTUnwrap(record.installations.first {
            $0.variantID == variant.id && $0.sha256 == variant.sha256 && $0.functionalityStatus != nil
        })
        XCTAssertEqual(receipt.build?.assetsSHA256, try LocalAPKBuildEvidence.assetsHash(variant))

        let configuration = try learning.confirmedConfiguration(receiptID: receipt.id, variant: variant, recipe: recipe)
        XCTAssertEqual(configuration.bundleId, receipt.bundleID)
        XCTAssertEqual(configuration.device, receipt.deviceID)
        XCTAssertEqual(configuration.team, receipt.team)
        XCTAssertEqual(configuration.localAPKVariantID, variant.id)
        let toolchain = try Toolchain(root: URL(fileURLWithPath: configuration.toolchain))
        XCTAssertEqual("\(toolchain.version())-\(toolchain.commit())", receipt.toolchain)
    }

    func testArchivedRE4BuildRecoversWithHistoricalManifestAndPreservesProvenance() throws {
        let base = DataLocation.defaultBase(bundleIdentifier: DataLocation.modifiedBundleIdentifier,
                                            support: DataLocation.applicationSupport)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let recipe = try RecipeStore(directory: repo.appendingPathComponent("recipes"))
            .load(id: "store-2637179839719680")
        let variants = LocalAPKVariantStore(root: base.appendingPathComponent("local-variants"))
        let variant = try XCTUnwrap(variants.variants(for: recipe).first {
            $0.id == "store-2637179839719680-203-46efcabd484e"
        })
        let learning = LocalAPKLearningStore(variants: variants)
        let record = try learning.load(recipe)
        let installation = try XCTUnwrap(record.installations.first { $0.variantID == variant.id })
        let legacy = try XCTUnwrap(installation.legacyRecovery)
        let jobID = legacy.buildJobID
        let archive = repo.appendingPathComponent("backups/isolado-125-to-126-20261025-122259/Application Support/AVPPlayModificado/jobs")
        let jobData = try Data(contentsOf: archive.appendingPathComponent(jobID + ".json"))
        let logData = try Data(contentsOf: archive.appendingPathComponent(jobID + ".log"))
        XCTAssertEqual(Hashing.sha256(of: jobData), legacy.sourceHashes[base.appendingPathComponent("jobs/\(jobID).json").path])
        XCTAssertEqual(Hashing.sha256(of: logData), legacy.sourceHashes[base.appendingPathComponent("jobs/\(jobID).log").path])
        let decoder = JSONDecoder.iso
        let job = try decoder.decode(Job.self, from: jobData)
        let toolchain = try Toolchain(root: URL(fileURLWithPath: job.request.toolchain))
        let log = try XCTUnwrap(String(data: logData, encoding: .utf8))
        let jobs = JobStore(directory: base.appendingPathComponent("jobs"))
        let app = legacy.unsignedApp
        XCTAssertTrue(log.contains(app.path))
        XCTAssertEqual(try LocalAPKBuildEvidence.recipeHash(job.recipe),
                       try LocalAPKBuildEvidence.recipeHash(recipe))
        XCTAssertEqual(toolchain.commit(), job.toolchainCommit)
        XCTAssertThrowsError(try ReusableBuild.find(jobs: jobs,
            workspaceRoot: base.appendingPathComponent("build-only"), recipe: recipe,
            request: job.request, bundleID: installation.bundleID, apkHash: variant.sha256,
            toolchain: toolchain, snapshots: [job], snapshotLogs: [jobID: log])) { error in
            XCTAssertTrue("\(error)".contains("Build anterior modificado ou sem metadados confiáveis"))
        }

        try FileManager.default.createDirectory(at: jobs.directory, withIntermediateDirectories: true)
        for (name, data) in [(jobID + ".json", jobData), (jobID + ".log", logData)] {
            let destination = jobs.directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: destination.path) {
                guard try Data(contentsOf: destination) == data else {
                    throw LocalAPKVariantError.invalidRecord("Job ativo divergente; não foi sobrescrito.")
                }
            } else {
                try data.write(to: destination, options: .withoutOverwriting)
            }
        }
        let recovered = try XCTUnwrap(LocalBuildRecovery(workspaceRoot: base.appendingPathComponent("build-only"))
            .artifact(jobs: jobs, recipe: recipe, variant: variant, toolchain: toolchain,
                     legacyInstallations: record.installations, variantStore: variants, report: { print($0) }))
        XCTAssertEqual(recovered.1.id, jobID)
        XCTAssertEqual(recovered.0.app.resolvingSymlinksInPath().standardizedFileURL.path,
                       app.resolvingSymlinksInPath().standardizedFileURL.path)
        XCTAssertEqual(try LocalAPKBuildEvidence.digest(recovered.0.files), installation.build?.unsignedBuildSHA256)
        XCTAssertEqual(try Data(contentsOf: jobs.directory.appendingPathComponent(jobID + ".json")), jobData)
        XCTAssertEqual(try Data(contentsOf: jobs.directory.appendingPathComponent(jobID + ".log")), logData)
        let receiptURL = base.appendingPathComponent("build-only/.build-receipts/\(jobID).json")
        let saved = try JSONDecoder().decode(LocalBuildReceipt.self, from: Data(contentsOf: receiptURL))
        XCTAssertEqual(saved.legacyProvenance?.installationReceiptID, installation.id)
        XCTAssertEqual(saved.legacyProvenance?.manifestSHA256, installation.build?.unsignedBuildSHA256)
        XCTAssertEqual(saved.legacyProvenance?.buildJobSHA256, legacy.sourceHashes[base.appendingPathComponent("jobs/\(jobID).json").path])
        XCTAssertEqual(saved.legacyProvenance?.buildLogSHA256, legacy.sourceHashes[base.appendingPathComponent("jobs/\(jobID).log").path])
        XCTAssertEqual(try saved.job().id, jobID)
        let reopened = try XCTUnwrap(LocalBuildRecovery(workspaceRoot: base.appendingPathComponent("build-only"))
            .artifact(jobs: jobs, recipe: recipe, variant: variant, toolchain: toolchain,
                     legacyInstallations: record.installations, variantStore: variants))
        XCTAssertEqual(reopened.0, recovered.0)
        XCTAssertEqual(reopened.1.id, jobID)
    }
}
