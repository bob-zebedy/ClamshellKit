@testable import ClamshellKit
import XCTest

final class ClamshellMonitorObservationTests: XCTestCase {
    func testObservationDeliversInitialValueThenChangesOnly() async throws {
        let source = TestAngleSource(
            angle: 30,
            maximumObservationFrequency: 200
        )
        let monitor = ClamshellMonitor(source: source)
        let stream = monitor.observe(
            options: .init(maximumFrequency: 100)
        )
        var iterator = stream.makeAsyncIterator()

        let initialValue = try await iterator.next()

        XCTAssertEqual(initialValue, ClamshellAngle(degrees: 30))

        let unchangedSnapshot = try await source.waitForSnapshot {
            $0.readCount > 1
        }
        XCTAssertGreaterThan(unchangedSnapshot.readCount, 1)

        source.setAngle(75)

        let changedValue = try await iterator.next()

        XCTAssertEqual(changedValue, ClamshellAngle(degrees: 75))
        XCTAssertEqual(source.snapshot.openCount, 1)
    }

    func testMultipleObserversShareConnection() async throws {
        let source = TestAngleSource(angle: 120)
        let monitor = ClamshellMonitor(source: source)

        let firstStream = monitor.observe()
        var firstIterator = firstStream.makeAsyncIterator()
        let firstValue = try await firstIterator.next()

        let secondStream = monitor.observe()
        var secondIterator = secondStream.makeAsyncIterator()
        let secondValue = try await secondIterator.next()

        XCTAssertEqual(firstValue, ClamshellAngle(degrees: 120))
        XCTAssertEqual(secondValue, ClamshellAngle(degrees: 120))
        XCTAssertEqual(source.snapshot.openCount, 1)
        XCTAssertEqual(source.snapshot.closeCount, 0)
    }

    func testObservationReconnectsAfterDisconnection() async throws {
        let source = TestAngleSource(
            angle: 45,
            maximumObservationFrequency: 200
        )
        let monitor = ClamshellMonitor(source: source)
        let stream = monitor.observe(
            options: .init(maximumFrequency: 100)
        )
        var iterator = stream.makeAsyncIterator()

        let initialValue = try await iterator.next()
        XCTAssertEqual(initialValue, ClamshellAngle(degrees: 45))

        source.setAngle(80)
        source.failNextReads(1, with: .disconnected)

        let recoveredValue = try await iterator.next()

        XCTAssertEqual(recoveredValue, ClamshellAngle(degrees: 80))
        XCTAssertEqual(source.snapshot.openCount, 2)
        XCTAssertEqual(source.snapshot.closeCount, 1)
    }

    func testCancellingObservationClosesConnection() async throws {
        let source = TestAngleSource(angle: 60)
        let monitor = ClamshellMonitor(source: source)
        let stream = monitor.observe()
        let receivedInitialValue = expectation(
            description: "Received initial angle"
        )

        let consumer = Task {
            var iterator = stream.makeAsyncIterator()
            _ = try await iterator.next()
            receivedInitialValue.fulfill()
            _ = try await iterator.next()
        }

        await fulfillment(of: [receivedInitialValue], timeout: 1)
        consumer.cancel()
        _ = await consumer.result

        let snapshot = try await source.waitForSnapshot {
            $0.closeCount == 1
        }
        XCTAssertEqual(snapshot.closeCount, 1)
    }

    func testDiscardingObservationClosesConnection() async throws {
        let source = TestAngleSource(angle: 60)
        let monitor = ClamshellMonitor(source: source)
        var stream: AsyncThrowingStream<ClamshellAngle, any Error>? = monitor.observe()
        var iterator = stream?.makeAsyncIterator()

        _ = try await iterator?.next()
        iterator = nil
        stream = nil

        let snapshot = try await source.waitForSnapshot {
            $0.closeCount == 1
        }
        XCTAssertEqual(snapshot.closeCount, 1)
    }
}
