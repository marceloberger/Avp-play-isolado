import XCTest
@testable import AVPPlayCore

final class RuntimeBuildPreferencesTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name="runtime-build-preferences-\(UUID().uuidString)"
        let suite=UserDefaults(suiteName:name)!
        suite.removePersistentDomain(forName:name)
        addTeardownBlock { suite.removePersistentDomain(forName:name) }
        return suite
    }

    func testMissingAndInvalidKeysMigrateToOriginalDefaults() {
        let defaults=defaults()
        XCTAssertEqual(RuntimeBuildPreferences.load(defaults:defaults),RuntimeBuildPreferences())
        defaults.set("invalid",forKey:RuntimeBuildPreferences.frameGenerationKey)
        defaults.set("invalid",forKey:RuntimeBuildPreferences.controllerModeKey)
        defaults.set("invalid",forKey:RuntimeBuildPreferences.surrealSDKKey)
        XCTAssertEqual(RuntimeBuildPreferences.load(defaults:defaults),RuntimeBuildPreferences())
    }

    func testGeneralSettingsPersistAndRoundTrip() {
        let defaults=defaults()
        let saved=RuntimeBuildPreferences(surrealSupport:false,controllerMode:.standard,
                                          frameGeneration:.ahead,surrealSDK:.verified)
        saved.save(defaults:defaults)
        XCTAssertEqual(RuntimeBuildPreferences.load(defaults:defaults),saved)
        var manual=saved; manual.frameGeneration = .off
        manual.save(defaults:defaults)
        XCTAssertEqual(RuntimeBuildPreferences.load(defaults:defaults).frameGeneration,.off)
    }

    func testPerGameOverridesWinAndUnspecifiedOptionsInheritGlobal() {
        let global=RuntimeBuildPreferences(surrealSupport:true,controllerMode:.standard,
                                           frameGeneration:.automatic,surrealSDK:.verified)
        XCTAssertEqual(global.resolve(),ResolvedRuntimeBuildPreferences(surrealSupport:true,controllerMode:.standard,
                        frameGeneration:.automatic,surrealSDK:.verified))
        let overridden=global.resolve(overrides:RuntimeBuildOverrides(surrealSupport:true,controllerMode:.surreal,
                        frameGeneration:.off,surrealSDK:.bluetooth))
        XCTAssertEqual(overridden,ResolvedRuntimeBuildPreferences(surrealSupport:true,controllerMode:.surreal,
                        frameGeneration:.off,surrealSDK:.bluetooth))
        let disabled=global.resolve(overrides:RuntimeBuildOverrides(surrealSupport:false,controllerMode:.surreal))
        XCTAssertEqual(disabled.controllerMode,.standard,"Disabled support resolves to Standard Controllers")
        XCTAssertEqual(disabled.frameGeneration,.automatic)
        XCTAssertEqual(disabled.surrealSDK,.verified)
    }

    func testResolvedJobSnapshotDoesNotChangeWhenGeneralPreferencesChange() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("runtime-pref-job-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at:root) }
        let store=JobStore(directory:root)
        let rootSource=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("recipes")
        var game=try RecipeStore(directory:rootSource).load(id:"batman")
        game.id="pref-fixture";game.title="Preference fixture"
        let initial=RuntimeBuildPreferences()
        let selected=initial.resolve(overrides:RuntimeBuildOverrides(frameGeneration:.between))
        var request=InstallRequest(toolchain:"/fixture")
        request.surrealSupport=selected.surrealSupport;request.controllerMode=selected.controllerMode
        request.frameGeneration=selected.frameGeneration;request.surrealSDK=selected.surrealSDK
        let job=Job(recipe:game,request:request,steps:[.buildOnly],toolchainCommit:"a61188d",suffix:"preference-snapshot")
        try store.save(job)
        var changed=initial;changed.surrealSupport=false;changed.frameGeneration = .off;changed.controllerMode = .surreal
        _=changed.resolve()
        let loaded=try store.load(job.id)
        XCTAssertEqual(loaded.request.frameGeneration,.between)
        XCTAssertEqual(loaded.request.controllerMode,.standard)
        XCTAssertEqual(loaded.request.surrealSupport,true)
        XCTAssertEqual(loaded.request.surrealSDK,.verified)
    }
}
