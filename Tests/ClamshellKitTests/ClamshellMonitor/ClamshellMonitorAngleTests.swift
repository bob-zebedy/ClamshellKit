@testable import ClamshellKit
import XCTest

final class ClamshellMonitorAngleTests: XCTestCase {
    func testAngleReturnsCurrentAngleUsingTransientConnection() async throws {
        let source = TestAngleSource(angle: 42)
        let monitor = ClamshellMonitor(source: source)

        let angle = try await monitor.angle()

        XCTAssertEqual(angle, ClamshellAngle(degrees: 42))
        XCTAssertEqual(
            source.snapshot,
            .init(openCount: 1, readCount: 1, closeCount: 1)
        )
    }
}
