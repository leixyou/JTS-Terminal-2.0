import CoreGraphics
import RemoteDesktopCore
import XCTest
@testable import JTSMacCompanion

final class DesktopInputControllerTests: XCTestCase {
    func testDisconnectReleasesHeldKeysAndButtonsOnce() async throws {
        try await MainActor.run {
            var posted: [CGEvent] = []
            let controller = DesktopInputController(permissionCheck: { true }, eventPoster: { posted.append($0) })
            try controller.handle(.key(keyCode: 0, isDown: true, modifiers: CGEventFlags.maskCommand.rawValue))
            try controller.handle(.pointer(x: 0.4, y: 0.6, button: .left, isDown: true))
            try controller.handle(.pointer(x: 0.6, y: 0.7))
            XCTAssertEqual(posted.map(\.type), [.keyDown, .leftMouseDown, .leftMouseDragged])

            try controller.handle(.releaseAll)
            XCTAssertEqual(posted.suffix(2).map(\.type), [.keyUp, .leftMouseUp])
            XCTAssertTrue(posted.suffix(2).allSatisfy { $0.flags.isEmpty })
            let countAfterRelease = posted.count
            controller.releaseAll()
            XCTAssertEqual(posted.count, countAfterRelease)
            try controller.handle(.pointer(x: 0.3, y: 0.3))
            XCTAssertEqual(posted.last?.type, .mouseMoved)
        }
    }

    func testAccessibilityRevocationRejectsInputAndClearsHeldState() async throws {
        try await MainActor.run {
            var isAllowed = true
            var posted: [CGEvent] = []
            let controller = DesktopInputController(permissionCheck: { isAllowed }, eventPoster: { posted.append($0) })
            try controller.handle(.key(keyCode: 12, isDown: true, modifiers: 0))
            isAllowed = false
            XCTAssertThrowsError(try controller.handle(.pointer(x: 0.1, y: 0.1)))
            XCTAssertEqual(posted.count, 1)
            isAllowed = true
            controller.releaseAll()
            XCTAssertEqual(posted.count, 1, "Revoked sessions cannot retain keys for a future session")
        }
    }

    func testRepeatedHardwareKeyProducesAutoRepeatAndInvalidInputPostsNothing() async throws {
        try await MainActor.run {
            var posted: [CGEvent] = []
            let controller = DesktopInputController(permissionCheck: { true }, eventPoster: { posted.append($0) })
            try controller.handle(.key(keyCode: 49, isDown: true, modifiers: 0))
            try controller.handle(.key(keyCode: 49, isDown: true, modifiers: 0))
            XCTAssertEqual(posted.first?.getIntegerValueField(.keyboardEventAutorepeat), 0)
            XCTAssertEqual(posted.last?.getIntegerValueField(.keyboardEventAutorepeat), 1)
            XCTAssertThrowsError(try controller.handle(.pointer(x: .infinity, y: 0.5)))
            XCTAssertEqual(posted.count, 2)
            controller.releaseAll()
        }
    }
}
