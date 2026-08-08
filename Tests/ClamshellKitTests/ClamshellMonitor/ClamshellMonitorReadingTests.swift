@testable import ClamshellKit
import XCTest

final class ClamshellMonitorReadingTests: XCTestCase {
    func testReadingReturnsStationaryMotionUsingTransientConnection() async throws {
        let source = TestAngleSource(
            angle: 75,
            maximumObservationFrequency: 200
        )
        let monitor = ClamshellMonitor(source: source)

        let reading = try await monitor.reading()

        XCTAssertEqual(
            reading,
            ClamshellReading(
                angle: ClamshellAngle(degrees: 75),
                angularVelocity: 0,
                angularAcceleration: 0
            )
        )

        let snapshot = try await source.waitForSnapshot {
            $0.closeCount == 1
        }
        XCTAssertEqual(snapshot.openCount, 1)
        XCTAssertGreaterThanOrEqual(snapshot.readCount, 5)
        XCTAssertEqual(snapshot.closeCount, 1)
    }
}
