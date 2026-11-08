import XCTest
import SwiftUI
import AppKit
@testable import AVPPlayCore
@testable import AVPPlayApp

final class LocalAppleSigningControlsTests: XCTestCase {
    func testManualIdentityDisclosureStartsCollapsed() {
        XCTAssertFalse(LocalBundleIdentityControls.initiallyExpanded)
    }

    private func headset(reachable: Bool = true, paired: Bool = true, developerMode: Bool = true,
                         connected: Bool = true) -> Device {
        Device(udid: "TEMPORARY-TEST-UDID", name: "Fixture Vision Pro", osVersion: "26.0",
               reachable: reachable, paired: paired, developerMode: developerMode, transport: .wifi, connected: connected)
    }

    func testConnectionStates136() {
        let connected = LocalAppleSigningControls.connectionDetail(device: headset(), problem: nil, refreshing: false, count: 1)
        XCTAssertTrue(connected.contains("conectado")); XCTAssertTrue(connected.contains("Wi-Fi") || connected.contains("WLAN"))
        XCTAssertTrue(LocalAppleSigningControls.connectionDetail(device: headset(connected: false), problem: nil, refreshing: false, count: 1).contains("espera"))
        XCTAssertTrue(LocalAppleSigningControls.connectionDetail(device: headset(reachable: false), problem: nil, refreshing: false, count: 1).contains("não acessível"))
        XCTAssertTrue(LocalAppleSigningControls.connectionDetail(device: headset(paired: false), problem: nil, refreshing: false, count: 1).contains("não emparelhado"))
        XCTAssertTrue(LocalAppleSigningControls.connectionDetail(device: headset(developerMode: false), problem: nil, refreshing: false, count: 1).contains("Modo de Desenvolvedor"))
    }

    func testRefreshErrorsAndAmbiguousSelection136() {
        XCTAssertTrue(LocalAppleSigningControls.connectionDetail(device: nil, problem: nil, refreshing: false, count: 0).contains("não conectado"))
        XCTAssertTrue(LocalAppleSigningControls.connectionDetail(device: nil, problem: nil, refreshing: false, count: 2).contains("Escolha"))
        XCTAssertEqual(LocalAppleSigningControls.connectionDetail(device: headset(), problem: "fixture error", refreshing: false, count: 1), "fixture error")
        XCTAssertTrue(LocalAppleSigningControls.connectionDetail(device: headset(), problem: "old error", refreshing: true, count: 1).contains("Verificando"))
    }

    @MainActor
    func testRenderingDoesNotChangeTeamOrStartDiscovery136() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("signing-controls-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(paths: Paths(recipes: nil, store: ContentStore(root: root.appendingPathComponent("store")),
            jobs: JobStore(directory: root.appendingPathComponent("jobs")),
            packager: ToolchainPackager(root: root.appendingPathComponent("toolchains"))), runJobsAutomatically: false)
        let originalTeam = model.teamId
        model.teamCandidates = [AppleTeam(id: "FIXTURE123", name: "Fixture Xcode Team", free: false)]
        for state in ["connected", "offline", "checking", "multiple"] {
            model.device = state == "offline" || state == "multiple" ? nil : headset()
            model.devices = state == "multiple" ? [headset(), Device(udid: "OTHER-TEST-UDID", name: "Other Fixture", osVersion: "26.0", reachable: true, paired: true, developerMode: true)] : []
            model.refreshing = state == "checking"
            model.deviceProblem = state == "offline" ? "Fixture: headset not reachable" : nil
            let view = GroupBox("Assinatura Apple") { LocalAppleSigningControls().padding(6) }
                .environmentObject(model).padding(24).frame(width: 850).background(Color.white).environment(\.colorScheme, .light)
            let hosting = NSHostingView(rootView: view.frame(height: 450))
            hosting.setFrameSize(NSSize(width: 850, height: 450)); hosting.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            if let output = ProcessInfo.processInfo.environment["AVPPLAY_SIGNING_PREVIEW"] {
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: output).appendingPathComponent("signing-\(state).png"))
            }
            XCTAssertEqual(model.teamId, originalTeam)
            XCTAssertEqual(model.refreshing, state == "checking", "Rendering must not trigger a probe")
            XCTAssertTrue(model.paths.jobs.all().isEmpty)
        }
    }
}
