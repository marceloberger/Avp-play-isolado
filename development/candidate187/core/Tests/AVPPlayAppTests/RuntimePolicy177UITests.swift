import XCTest
import SwiftUI
import AppKit
@testable import AVPPlayApp
@testable import AVPPlayCore

final class RuntimePolicy177UITests: XCTestCase {
    @MainActor
    func testFixedRuntimeUIAndLegacyChoiceDoesNotWritePins() async throws {
        let resources = try XCTUnwrap(ProcessInfo.processInfo.environment["AVPPLAY_TEST_RUNTIME850_RESOURCES"])
        let packager = ToolchainPackager(root: DataLocation.base.appendingPathComponent("toolchains"))
        _ = try OptionalRuntime850.install(resources: URL(fileURLWithPath: resources), packager: packager)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let recipe = try RecipeStore(directory: root.appendingPathComponent("recipes")).load(id: "store-3240283705987790")
        let paths = Paths(recipes: root.appendingPathComponent("recipes"), store: ContentStore(root: DataLocation.base.appendingPathComponent("store")), jobs: JobStore(directory: DataLocation.base.appendingPathComponent("jobs")), packager: packager)
        let model = AppModel(paths: paths, runJobsAutomatically: false)
        let game = model.localGame(for: recipe)
        let choices = ToolchainChoices(games: [game.id: .init(version: 824, commit: "a61188d")])
        try choices.save()
        let before = try Data(contentsOf: ToolchainChoices.url)
        defer { try? FileManager.default.removeItem(at: ToolchainChoices.url) }
        XCTAssertEqual(model.toolchain(for: game)?.version(), 850)
        XCTAssertEqual(paths.toolchain()?.version(), 850)
        model.chooseToolchain(game, .init(id: "old", kind: .installed, version: 824, commit: "a61188d"))
        XCTAssertEqual(try Data(contentsOf: ToolchainChoices.url), before)
        let view = NSHostingView(rootView: ToolchainBox(game: game).environmentObject(model))
        view.frame = NSRect(x:0,y:0,width:800,height:500); view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(view.fittingSize.height, 0)
        XCTAssertTrue(model.toolchainNote[game.id]?.contains("TLS168") == true)
        var job = Job(recipe: recipe, request: InstallRequest(toolchain: "/old824"), steps: [.buildOnly], toolchainCommit: "a61188d")
        job.state = .failed
        try paths.jobs.save(job)
        let saved = try Data(contentsOf: paths.jobs.url(job.id))
        model.resume(job)
        for _ in 0..<100 {
            if !model.resumingJobIDs.contains(job.id) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.resumingJobIDs.contains(job.id), "Runtime preflight must finish")
        XCTAssertTrue(model.queued.isEmpty)
        XCTAssertEqual(try Data(contentsOf: paths.jobs.url(job.id)), saved)
        XCTAssertTrue(model.resumeMessages[job.id]?.contains("Build177") == true)
    }
}
