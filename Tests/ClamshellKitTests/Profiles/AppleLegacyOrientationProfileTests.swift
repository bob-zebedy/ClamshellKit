@testable import ClamshellKit
import XCTest

final class AppleLegacyOrientationProfileTests: XCTestCase {
    private let profile = AppleLegacyOrientationProfile()

    func testMaximumObservationFrequencyIsSixtyHertz() {
        XCTAssertEqual(profile.maximumObservationFrequency, 60)
    }

    func testDecodesLittleEndianAngle() throws {
        let angle = try profile.decode(
            report: [1, 0x0E, 0x01, 0, 0, 0, 0, 0],
            length: 8
        )

        XCTAssertEqual(angle, ClamshellAngle(degrees: 270))
    }

    func testRejectsShortReport() {
        XCTAssertThrowsError(
            try profile.decode(report: [1, 90], length: 2)
        ) { error in
            XCTAssertEqual(error as? ClamshellError, .invalidData)
        }
    }

    func testRejectsAngleOutsideLogicalRange() {
        XCTAssertThrowsError(
            try profile.decode(report: [1, 0x69, 0x01], length: 3)
        ) { error in
            XCTAssertEqual(error as? ClamshellError, .invalidData)
        }
    }
}
