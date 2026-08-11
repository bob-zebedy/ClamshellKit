@testable import ClamshellKit
import XCTest

final class ClamshellMonitorDiagnosticsTests: XCTestCase {
    func testCreatingDiagnosticsStreamDoesNotOpenSource() {
        let source = TestAngleSource(angle: 42)
        let monitor = ClamshellMonitor(source: source)

        _ = monitor.observeDiagnostics(options: .init(level: .trace))

        XCTAssertEqual(
            source.snapshot,
            .init(openCount: 0, readCount: 0, closeCount: 0)
        )
    }

    func testBasicDiagnosticsReportStatusFailure() async throws {
        let source = TestAngleSource(angle: 0, openError: .notFound)
        let monitor = ClamshellMonitor(source: source)
        let stream = monitor.observeDiagnostics(options: .init(level: .basic))
        var iterator = stream.makeAsyncIterator()

        let status = await monitor.status
        let nextEvent = await iterator.next()
        let event = try XCTUnwrap(nextEvent)

        XCTAssertEqual(status, .notFound)
        XCTAssertEqual(event.kind, .failure)
        XCTAssertEqual(event.fields["operation"], .string("status"))
        XCTAssertEqual(event.fields["error"], .string("notFound"))
    }

    func testTraceDiagnosticsDoNotChangeReadingOutput() async throws {
        let source = TestAngleSource(
            angle: 75,
            maximumObservationFrequency: 200
        )
        let monitor = ClamshellMonitor(source: source)
        let stream = monitor.observeDiagnostics(options: .init(level: .trace))
        let diagnosticConsumer = Task<ClamshellDiagnosticEvent?, Never> {
            for await event in stream where event.kind == .estimatorAcceleration {
                return event
            }

            return nil
        }

        let reading = try await monitor.reading()
        let diagnosticEventValue = await diagnosticConsumer.value
        let diagnosticEvent = try XCTUnwrap(diagnosticEventValue)

        XCTAssertEqual(
            reading,
            ClamshellReading(
                angle: ClamshellAngle(degrees: 75),
                angularVelocity: 0,
                angularAcceleration: 0
            )
        )
        XCTAssertEqual(
            diagnosticEvent.fields["filteredAcceleration"],
            .floatingPoint(0)
        )
    }
}
