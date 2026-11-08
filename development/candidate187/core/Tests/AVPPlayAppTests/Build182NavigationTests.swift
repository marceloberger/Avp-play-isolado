import XCTest
@testable import AVPPlayApp

final class Build182NavigationTests: XCTestCase {
    func testLibraryIsAdditionalNavigationAndAllPreviousDestinationsRemain() {
        XCTAssertEqual(AppSection.allCases.first, .library)
        for section: AppSection in [.games, .filters, .localLibrary, .jobs, .setup, .settings, .remote, .appleMusic, .data] {
            XCTAssertTrue(AppSection.allCases.contains(section))
        }
        XCTAssertEqual(AppSection.library.title, "Minha biblioteca")
        XCTAssertEqual(AppSection.allCases.last, .settings)
    }
}

import AppKit
import SwiftUI
@testable import AVPPlayCore

extension Build182NavigationTests {
    @MainActor
    func testCardRendersWithoutAppModelDeviceOrNetwork() throws {
        // Explicit synthetic QA fixture, never inserted into a library or persisted as a Job.
        let entry = LibraryEntry182(id: "fixture", title: "Fixture · sem instalação real", package: "example.fixture",
            target: nil, recipe: nil, provisional: true, status: .experimental, evidence: "Fixture", variantCount: 1, jobs: [])
        let card = LibraryGameCard182(entry: entry, progress: nil, open: {}, jobs: {}).frame(width: 280, height: 410)
        let view = NSHostingView(rootView: card)
        view.frame = NSRect(x: 0, y: 0, width: 280, height: 410)
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 1000)
        try data.write(to: URL(fileURLWithPath: "/private/tmp/avp182-card-qa.png"))
    }
}
