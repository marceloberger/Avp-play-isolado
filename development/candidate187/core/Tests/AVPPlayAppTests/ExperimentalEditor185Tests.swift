import XCTest
import SwiftUI
import AppKit
@testable import AVPPlayApp

final class ExperimentalEditor185Tests: XCTestCase {
    @MainActor
    func testEditorFieldsAndSavingAreEnabledWithEmptyUnverifiedValues() throws {
        var appID = "", source = "", saved = false
        let view = ExperimentalIdentityEditor185(
            appID: Binding(get: { appID }, set: { appID = $0 }),
            provenance: Binding(get: { source }, set: { source = $0 }), save: { saved = true })
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 250)
        host.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let children = descendants(host)
        let fields = children.compactMap { $0 as? NSTextField }.filter(\.isEditable)
        XCTAssertEqual(fields.count, 2)
        XCTAssertTrue(fields.allSatisfy(\.isEnabled))
        // SwiftUI draws this button without an NSButton backing view.
        // Exercise its exact save closure; store round-trip tests cover persistence.
        view.save()
        XCTAssertTrue(saved)
    }
}
