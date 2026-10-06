import CoreGraphics
import XCTest
@testable import JTSMacCompanion

final class DesktopInputCoordinatesTests: XCTestCase {
    func testNormalizedCornersRemainInsideDisplay() throws {
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(try DesktopInputCoordinates.point(x: 0, y: 0, in: bounds), .zero)
        let bottomRight = try DesktopInputCoordinates.point(x: 1, y: 1, in: bounds)
        XCTAssertEqual(bottomRight, CGPoint(x: 1919, y: 1079))
        XCTAssertTrue(bounds.contains(bottomRight))
    }

    func testDisplayOriginIsPreservedForMultiDisplayCoordinates() throws {
        let bounds = CGRect(x: -1440, y: -300, width: 1440, height: 900)
        XCTAssertEqual(try DesktopInputCoordinates.point(x: 0, y: 0, in: bounds), bounds.origin)
        XCTAssertEqual(try DesktopInputCoordinates.point(x: 1, y: 1, in: bounds), CGPoint(x: -1, y: 599))
        XCTAssertEqual(try DesktopInputCoordinates.point(x: 0.5, y: 0.5, in: bounds),
                       CGPoint(x: -720.5, y: 149.5))
    }

    func testInvalidCoordinatesAndDisconnectedDisplayAreRejected() {
        let bounds = CGRect(x: 0, y: 0, width: 1280, height: 720)
        for value in [-0.001, 1.001, Double.nan, Double.infinity] {
            XCTAssertThrowsError(try DesktopInputCoordinates.point(x: value, y: 0.5, in: bounds))
            XCTAssertThrowsError(try DesktopInputCoordinates.point(x: 0.5, y: value, in: bounds))
        }
        XCTAssertThrowsError(try DesktopInputCoordinates.point(x: 0.5, y: 0.5, in: .zero))
    }
}
