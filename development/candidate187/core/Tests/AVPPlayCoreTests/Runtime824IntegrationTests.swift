import XCTest
@testable import AVPPlayCore

final class Runtime824IntegrationTests: XCTestCase {
    private func recipe(_ version: Int = 3237) throws -> Recipe {
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let store=RecipeStore(directory:root.appendingPathComponent("recipes"))
        return try XCTUnwrap(version==3237 ? store.loadVariants().first {$0.id=="beatsaber140" && $0.versionCode==3237}
                             : store.loadAll().first {$0.id=="beatsaber140"})
    }
    private func recipe(id: String) throws -> Recipe {
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try RecipeStore(directory:root.appendingPathComponent("recipes")).load(id:id)
    }
    private func runtime() throws -> Toolchain {
        let root=URL(fileURLWithPath:"/private/tmp/klepton824-release156")
        guard FileManager.default.fileExists(atPath:root.appendingPathComponent("toolchain.json").path) else {
            throw XCTSkip("Validated official 824 fixture not staged")
        }
        return try Toolchain(root:root)
    }
    private func runtimeWithVerifiedSDK() throws -> Toolchain {
        let runtime = try Verified850Fixture.source()
        try OptionalRuntime850.verifySDK(at: runtime.root)
        return runtime
    }
    func testExactVersionModProfileAndExplicitDefaults() throws {
        let runtime=try runtime(),recipe=try recipe()
        var request=InstallRequest(toolchain:runtime.root.path);request.surrealSDK = .bluetooth
        var environment=try runtime.runtimeEnvironment(recipe:recipe,request:request)
        XCTAssertEqual(environment["KLEPTON_SCOTLAND2"],"0")
        XCTAssertNil(environment["KLEPTON_FRAMEGEN"], "Automatic must defer to Klepton's target preset")
        request.frameGeneration = .off
        environment=try runtime.runtimeEnvironment(recipe:recipe,request:request)
        XCTAssertEqual(environment["KLEPTON_FRAMEGEN"],"off", "Explicit Off must be sent")
        request.coreMods=true;request.frameGeneration = .between
        environment=try runtime.runtimeEnvironment(recipe:recipe,request:request)
        XCTAssertEqual(environment["SC2_GAME_PROFILE"],"1.45.3")
        XCTAssertEqual(environment["SC2_TEST_SET"],"coremods")
        XCTAssertEqual(environment["SC2_BUILD_MODE"],"release")
        XCTAssertEqual(environment["KLEPTON_SCOTLAND2"],"1")
        XCTAssertEqual(environment["KLEPTON_FRAMEGEN"],"between")
        XCTAssertThrowsError(try runtime.runtimeEnvironment(recipe:try self.recipe(3148),request:request))
    }
    func testAutomaticFrameGenerationUses824TargetPresetAndManualChoicesAreExplicit() throws {
        let runtime=try runtime(), recipe=try recipe()
        XCTAssertEqual(runtime.frameGenerationDefault(for:"alyx"), .between)
        XCTAssertEqual(runtime.frameGenerationDefault(for:"deadpool"), .off)
        var request=InstallRequest(toolchain:runtime.root.path); request.surrealSDK = .bluetooth
        XCTAssertEqual(request.frameGeneration, .automatic)
        XCTAssertNil(try runtime.runtimeEnvironment(recipe:recipe,request:request)["KLEPTON_FRAMEGEN"])
        for mode in [FrameGeneration.off, .ahead, .between] {
            request.frameGeneration=mode
            XCTAssertEqual(try runtime.runtimeEnvironment(recipe:recipe,request:request)["KLEPTON_FRAMEGEN"], mode.rawValue)
        }
        request.frameGeneration=nil // persisted pre-161 Jobs keep historical Off
        XCTAssertEqual(try runtime.runtimeEnvironment(recipe:recipe,request:request)["KLEPTON_FRAMEGEN"], "off")
    }
    func testSurrealSDKVerifiedIsDefaultAndBluetoothIsExplicitFallback() throws {
        let runtime=try runtimeWithVerifiedSDK(), recipe=try recipe()
        let defaultRequest=InstallRequest(toolchain:runtime.root.path)
        let verified=try runtime.runtimeEnvironment(recipe:recipe,request:defaultRequest)
        XCTAssertEqual(verified["KLEPTON_SURREAL_SUPPORT"],"1")
        XCTAssertEqual(verified["KLEPTON_SURREAL_SDK"],"1")
        var fallback=defaultRequest; fallback.surrealSDK = .bluetooth
        XCTAssertEqual(try runtime.runtimeEnvironment(recipe:recipe,request:fallback)["KLEPTON_SURREAL_SDK"],"0")
    }
    func testSDKFailureRequiresAnExplicitFallback() throws {
        let runtime=try runtime(),recipe=try recipe()
        var request=InstallRequest(toolchain:runtime.root.path);request.controllerMode = .surreal
        XCTAssertThrowsError(try runtime.runtimeEnvironment(recipe:recipe,request:request))
        request.surrealSDK = .bluetooth
        XCTAssertEqual(try runtime.runtimeEnvironment(recipe:recipe,request:request)["KLEPTON_SURREAL_SDK"],"0")
        request.surrealSupport=false;request.surrealSDK = .verified
        let env=try runtime.runtimeEnvironment(recipe:recipe,request:request)
        XCTAssertEqual(env["KLEPTON_SURREAL_SUPPORT"],"0");XCTAssertEqual(env["KLEPTON_CONTROLLER_MODE"],"standard")
    }
    func test750NeverAccepts824OnlyOptions() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("avp156-legacy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at:root) }
        try FileManager.default.createDirectory(at:root.appendingPathComponent("visionos"),withIntermediateDirectories:true)
        try Data("#!/bin/sh\n".utf8).write(to:root.appendingPathComponent("visionos/run.sh"))
        try Data("# old generator, no new capability\n".utf8).write(to:root.appendingPathComponent("visionos/gen_xcodeproj.py"))
        let old=try Toolchain(root:root)
        var request=InstallRequest(toolchain:root.path);request.frameGeneration = .ahead
        XCTAssertThrowsError(try old.runtimeEnvironment(recipe:try recipe(),request:request))
        request.frameGeneration = .off;request.coreMods=true
        XCTAssertThrowsError(try old.runtimeEnvironment(recipe:try recipe(),request:request))
        request.coreMods=false
        XCTAssertEqual(try old.runtimeEnvironment(recipe:try recipe(),request:request)["KLEPTON_CONTROLLER_MODE"],"standard")
    }
    func testRE4AdapterAcceptsActual824TargetsWithoutChangingOtherTargets() throws {
        let runtime=try runtime()
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("avp156-re4-target-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at:root) }
        let file=root.appendingPathComponent("visionos/targets.py")
        try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
        try FileManager.default.copyItem(at:runtime.root.appendingPathComponent("visionos/targets.py"),to:file)
        try KleptonRecipeCompatibility.addResidentEvilTargetMetadata(to:root)
        let modified=try Data(contentsOf:file)
        try KleptonRecipeCompatibility.addResidentEvilTargetMetadata(to:root)
        XCTAssertEqual(try Data(contentsOf:file),modified)
        XCTAssertTrue(String(decoding:modified,as:UTF8.self).contains(KleptonRecipeCompatibility.residentEvilOBBFile))
        XCTAssertNotEqual(file,runtime.root.appendingPathComponent("visionos/targets.py"))
    }
    func testMetalFXAndFrameGenerationTravelTogetherToTheRealGenerator() throws {
        let runtime=try runtime()
        var request=InstallRequest(toolchain:runtime.root.path)
        request.surrealSDK = .bluetooth;request.frameGeneration = .ahead
        request.metalFX=true;request.resolution=75
        let env=try runtime.runtimeEnvironment(recipe:try recipe(),request:request)
        XCTAssertEqual(env["KLEPTON_FRAMEGEN"],"ahead")
        XCTAssertTrue(env["KLEPTON_TEST_ON",default:""].contains(Toolchain.metalFXSwitch))
        XCTAssertEqual(env[Toolchain.renderScaleVariable],"0.75")
    }
    func testVerifiedOptionalInstallInTemporaryRootKeeps750DefaultAndDetectsCorruption() throws {
        let resources=URL(fileURLWithPath:"/private/tmp/avp156-resource-fixtures")
        guard FileManager.default.fileExists(atPath:resources.appendingPathComponent(OptionalRuntime824.archiveName).path) else {
            throw XCTSkip("Official archives not staged")
        }
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("avp156-optional-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at:root) }
        let packager=ToolchainPackager(root:root)
        let old=root.appendingPathComponent("750-900daf8")
        try FileManager.default.createDirectory(at:old.appendingPathComponent("visionos"),withIntermediateDirectories:true)
        try Data("#!/bin/sh\n".utf8).write(to:old.appendingPathComponent("visionos/run.sh"))
        let manifest=Data(#"{"format":1,"version":750,"commit":"900daf8","ancestors":["900daf8"],"created":"2026-01-01T00:00:00Z"}"#.utf8)
        try manifest.write(to:old.appendingPathComponent("toolchain.json"))
        let installed=try OptionalRuntime824.install(resources:resources,packager:packager)
        XCTAssertEqual(installed.commit(),"a61188d");try OptionalRuntime824.verifySDK(at:installed.root)
        let receiptData=try Data(contentsOf:installed.root.appendingPathComponent(".isolated-source-sha256.json"))
        let receipt=try JSONDecoder().decode([String:String].self,from:receiptData)
        XCTAssertNotNil(receipt["visionos/Sources/kl_app.c"],"Official 824 places kl_app.c under visionos/Sources")
        XCTAssertNil(receipt["runtime/kl_app.c"],"Do not depend on a path absent from the official archive")
        XCTAssertTrue(OptionalRuntime824.hasVerifiedReceipt(for:installed))
        XCTAssertEqual(packager.verified824()?.commit(),"a61188d")
        XCTAssertEqual(packager.build158Toolchain(for:try recipe())?.commit(),"a61188d")
        XCTAssertEqual(packager.functionalDefault()?.commit(),"900daf8")
        XCTAssertEqual(try Data(contentsOf:old.appendingPathComponent("toolchain.json")),manifest)
        XCTAssertTrue(try packager.prune(keep:1).isEmpty)
        var request=InstallRequest(toolchain:installed.root.path);request.coreMods=true
        XCTAssertEqual(try installed.runtimeEnvironment(recipe:try recipe(),request:request)["KLEPTON_SURREAL_SDK"],"1")
        let officialSource=installed.root.appendingPathComponent("visionos/Sources/kl_app.c")
        let officialSourceBytes=try Data(contentsOf:officialSource)
        try Data("corrupt critical source".utf8).write(to:officialSource)
        XCTAssertFalse(OptionalRuntime824.hasVerifiedReceipt(for:installed),"A changed critical source must fail closed")
        XCTAssertNil(packager.verified824())
        XCTAssertNil(packager.build158Toolchain(for:try recipe()))
        try officialSourceBytes.write(to:officialSource)
        XCTAssertTrue(OptionalRuntime824.hasVerifiedReceipt(for:installed))
        try Data("corrupt fixture".utf8).write(to:installed.root.appendingPathComponent("visionos/Frameworks/\(OptionalRuntime824.sdkName).xcframework/Info.plist"))
        XCTAssertThrowsError(try OptionalRuntime824.install(resources:resources,packager:packager))
    }

    func testInstalledRuntime824IsRecognizedIfPathIsProvided() throws {
        guard let path=ProcessInfo.processInfo.environment["AVPPLAY_TEST_INSTALLED_824"] else {
            throw XCTSkip("Set AVPPLAY_TEST_INSTALLED_824 to validate a user's installed runtime")
        }
        let runtimeRoot=URL(fileURLWithPath:path,isDirectory:true)
        let packager=ToolchainPackager(root:runtimeRoot.deletingLastPathComponent())
        XCTAssertEqual(packager.verified824()?.root.standardizedFileURL,runtimeRoot.standardizedFileURL)
        XCTAssertEqual(packager.build158Toolchain(for:try recipe())?.commit(),"a61188d")
        XCTAssertEqual(packager.functionalDefault()?.version(),750,"Installing/recognizing 824 must keep 750 as the functional default")
        let deadpool=try recipe(id:"store-3240283705987790")
        let ghostbusters=try recipe(id:"store-4746232908818706")
        let gunClub=try recipe(id:"store-2285803881494677")
        XCTAssertEqual(packager.build158Toolchain(for:deadpool)?.commit(),"a61188d",
                       "The verified installed 824 contains Deadpool's exact target and minimum commit")
        XCTAssertTrue(packager.verified824()?.satisfies(minCommit:gunClub.toolchain.minCommit) == true,
                       "Long recipe hashes must match abbreviated manifest ancestors")
        XCTAssertFalse(packager.verified824()?.hasTarget(ghostbusters.toolchain.target) ?? true)
        XCTAssertEqual(packager.build158Toolchain(for:ghostbusters)?.commit(),"a61188d",
                       "Ghostbusters should be admitted as an experimental generic target")
        XCTAssertEqual(Toolchain.genericEnvironment(recipe:ghostbusters)["KLEPTON_GENERIC_TARGET"],
                       "x4746232908818706")

        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let all=try RecipeStore(directory:root.appendingPathComponent("recipes")).loadAll()
        let accepted=all.compactMap { item -> (Recipe,Bool)? in
            let resolved=KleptonRecipeCompatibility.resolve(item)
            guard packager.build158Toolchain(for:resolved) != nil else { return nil }
            return (item,packager.verified824()?.hasTarget(resolved.toolchain.target) == true)
        }
        XCTAssertEqual(all.count,48,"Keep the shipped recipe inventory under this compatibility audit")
        XCTAssertEqual(accepted.count,48,"Every shipped recipe must satisfy either target route and its commit minimum")
        XCTAssertEqual(accepted.filter { $0.1 }.count,26,"Explicit 824 targets are accepted")
        XCTAssertEqual(accepted.filter { !$0.1 }.count,22,"Valid generic targets are accepted experimentally")
    }
}
