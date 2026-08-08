@testable import ClamshellKit
import XCTest

final class ClamshellMonitorStatusTests: XCTestCase {
    func testStatusIsAvailableWhenReadingSucceeds() async {
        let source = TestAngleSource(angle: 90)
        let monitor = ClamshellMonitor(source: source)

        let status = await monitor.status

        XCTAssertEqual(status, .available)
        XCTAssertEqual(
            source.snapshot,
            .init(openCount: 1, readCount: 1, closeCount: 1)
        )
    }

    func testStatusIsNotFoundWhenSourceIsMissing() async {
        let source = TestAngleSource(angle: 0, openError: .notFound)
        let monitor = ClamshellMonitor(source: source)

        let status = await monitor.status

        XCTAssertEqual(status, .notFound)
    }

    func testStatusIsAccessDeniedWhenSourceCannotBeOpened() async {
        let source = TestAngleSource(angle: 0, openError: .accessDenied)
        let monitor = ClamshellMonitor(source: source)

        let status = await monitor.status

        XCTAssertEqual(status, .accessDenied)
    }

    func testStatusIsUnsupportedWhenSourceReturnsInvalidData() async {
        let source = TestAngleSource(angle: 0, readError: .invalidData)
        let monitor = ClamshellMonitor(source: source)

        let status = await monitor.status

        XCTAssertEqual(status, .unsupported)
    }
}
