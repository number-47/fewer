import XCTest
@testable import FewerCore

final class RollingScrollCommandTests: XCTestCase {
    func testCommandPropertyListRoundTrip() {
        let command = RollingScrollCommand(
            sessionID: UUID(),
            requestID: UUID(),
            screenX: 420.5,
            screenY: 315.25,
            direction: .up,
            distance: 480
        )!

        XCTAssertEqual(RollingScrollCommand(userInfo: command.userInfo), command)
    }

    func testLegacyCommandDefaultsToDownwardDirection() {
        let command = RollingScrollCommand(
            sessionID: UUID(),
            requestID: UUID(),
            screenX: 1,
            screenY: 2,
            distance: 20
        )!
        var legacy = command.userInfo
        legacy.removeValue(forKey: "direction")

        XCTAssertEqual(RollingScrollCommand(userInfo: legacy)?.direction, .down)
    }

    func testDirectionProducesExpectedWheelSign() {
        XCTAssertEqual(RollingScrollDirection.up.signedDistanceMultiplier, 1)
        XCTAssertEqual(RollingScrollDirection.down.signedDistanceMultiplier, -1)
    }

    func testCommandSplitsLargeScrollIntoSmallPixelDeltas() throws {
        let down = try XCTUnwrap(RollingScrollCommand(
            sessionID: UUID(),
            requestID: UUID(),
            screenX: 100,
            screenY: 200,
            direction: .down,
            distance: 25
        ))
        XCTAssertEqual(down.eventDeltas(), [-10, -10, -5])

        let up = try XCTUnwrap(RollingScrollCommand(
            sessionID: UUID(),
            requestID: UUID(),
            screenX: 100,
            screenY: 200,
            direction: .up,
            distance: 25
        ))
        XCTAssertEqual(up.eventDeltas(maximumMagnitude: 8), [8, 8, 8, 1])
    }

    func testCommandRejectsInvalidDistance() {
        XCTAssertNil(RollingScrollCommand(
            sessionID: UUID(),
            requestID: UUID(),
            screenX: 100,
            screenY: 100,
            distance: 0
        ))
        XCTAssertNil(RollingScrollCommand(
            sessionID: UUID(),
            requestID: UUID(),
            screenX: 100,
            screenY: 100,
            distance: RollingScrollCommand.maximumDistance + 1
        ))
    }

    func testResponsePropertyListRoundTrip() {
        let response = RollingScrollResponse(
            sessionID: UUID(),
            requestID: UUID(),
            reason: .accessibilityDenied
        )

        XCTAssertEqual(RollingScrollResponse(userInfo: response.userInfo), response)
    }

}
