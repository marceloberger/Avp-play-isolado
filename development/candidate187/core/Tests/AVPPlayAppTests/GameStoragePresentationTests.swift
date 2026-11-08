import XCTest
import SwiftUI
import AppKit
@testable import AVPPlayCore
@testable import AVPPlayApp

final class GameStoragePresentationTests: XCTestCase {
    @MainActor
    func testTotalsViewRendersCompleteAndPartialGamesWithoutReadingOrChangingUserData() throws {
        let inventory = LocalStorageInventory(entries: [], games: [
            GameStorageTotal(id: "re4", title: "Resident Evil 4", bytes: 2_567_000_000, partial: true),
            GameStorageTotal(id: "batman", title: "Batman: Arkham Shadow", bytes: 20_844_000_000)], unassignedBytes: 1234)
        let view = StorageInventoryView(inventory: inventory).padding(24).frame(width: 820)
            .background(Color.white).environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        XCTAssertGreaterThan(image.width, 800)
        XCTAssertGreaterThan(image.height, 250)
        if let output = ProcessInfo.processInfo.environment["AVPPLAY_GAME_TOTALS_PREVIEW"] {
            let bitmap = NSBitmapImageRep(cgImage: image)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output))
        }
    }
}
