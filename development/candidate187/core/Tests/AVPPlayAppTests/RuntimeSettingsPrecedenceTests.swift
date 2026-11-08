import XCTest
@testable import AVPPlayApp
@testable import AVPPlayCore

final class RuntimeSettingsPrecedenceTests: XCTestCase {
    func testLegacyPerGameSettingsDecodeAsInheritAndExplicitOverridesPersist() throws {
        let current=GameOptions()
        XCTAssertNil(current.frameGeneration)
        XCTAssertNil(current.controllerMode)
        XCTAssertNil(current.surrealSupport)
        XCTAssertNil(current.surrealSDK)
        let encoded=try JSONEncoder().encode(current)
        let decoded=try JSONDecoder().decode(GameOptions.self,from:encoded)
        XCTAssertNil(decoded.frameGeneration);XCTAssertNil(decoded.controllerMode)
        XCTAssertNil(decoded.surrealSupport);XCTAssertNil(decoded.surrealSDK)

        var explicit=current
        explicit.frameGeneration = .automatic
        explicit.controllerMode = .surreal
        explicit.surrealSupport = false
        explicit.surrealSDK = .bluetooth
        let roundTrip=try JSONDecoder().decode(GameOptions.self,from:JSONEncoder().encode(explicit))
        XCTAssertEqual(roundTrip.frameGeneration,.automatic)
        XCTAssertEqual(roundTrip.controllerMode,.surreal)
        XCTAssertEqual(roundTrip.surrealSupport,false)
        XCTAssertEqual(roundTrip.surrealSDK,.bluetooth)
    }
}
