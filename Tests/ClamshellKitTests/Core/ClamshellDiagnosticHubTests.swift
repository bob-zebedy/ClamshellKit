@testable import ClamshellKit
import XCTest

final class ClamshellDiagnosticHubTests: XCTestCase {
    func testOffStreamFinishesImmediately() async {
        let hub = ClamshellDiagnosticHub()
        let stream = hub.stream(options: .init(level: .off))
        var iterator = stream.makeAsyncIterator()

        let event = await iterator.next()

        XCTAssertNil(event)
    }

    func testEachLevelReceivesOnlyIncludedEvents() async throws {
        let hub = ClamshellDiagnosticHub()
        let basicStream = hub.stream(options: .init(level: .basic))
        let verboseStream = hub.stream(options: .init(level: .verbose))
        let traceStream = hub.stream(options: .init(level: .trace))

        hub.emit(.sourceOpened, level: .basic, fields: [:])
        hub.emit(.reportRead, level: .verbose, fields: [:])
        hub.emit(.rawReport, level: .trace, fields: [:])
        hub.emit(.sourceClosed, level: .basic, fields: [:])

        let basicEvents = try await nextEvents(2, from: basicStream)
        let verboseEvents = try await nextEvents(3, from: verboseStream)
        let traceEvents = try await nextEvents(4, from: traceStream)

        XCTAssertEqual(
            basicEvents.map(\.kind),
            [.sourceOpened, .sourceClosed]
        )
        XCTAssertEqual(
            verboseEvents.map(\.kind),
            [.sourceOpened, .reportRead, .sourceClosed]
        )
        XCTAssertEqual(
            traceEvents.map(\.kind),
            [.sourceOpened, .reportRead, .rawReport, .sourceClosed]
        )
    }

    func testBufferKeepsNewestEvents() async throws {
        let hub = ClamshellDiagnosticHub()
        let stream = hub.stream(options: .init(level: .trace))

        for index in 0 ..< 300 {
            hub.emit(
                .estimatorSample,
                level: .trace,
                fields: ["index": .integer(Int64(index))]
            )
        }

        let events = try await nextEvents(256, from: stream)

        XCTAssertEqual(events.first?.fields["index"], .integer(44))
        XCTAssertEqual(events.last?.fields["index"], .integer(299))
    }

    func testDescriptionFormatsSortedFieldsAndRawBytes() {
        let event = ClamshellDiagnosticEvent(
            level: .trace,
            uptimeNanoseconds: 1,
            kind: .rawReport,
            fields: [
                "reportID": .integer(1),
                "bytes": .bytes([0x01, 0x0E, 0x01])
            ]
        )

        XCTAssertEqual(
            event.description,
            "[ClamshellKit][report.raw] bytes=01 0E 01 reportID=1"
        )
    }

    func testCancellingConsumerDisablesItsSubscription() async {
        let hub = ClamshellDiagnosticHub()
        let stream = hub.stream(options: .init(level: .trace))
        let consumer = Task {
            for await _ in stream {}
        }

        consumer.cancel()
        await consumer.value

        let fieldProbe = DiagnosticFieldProbe()
        hub.emit(
            .estimatorSample,
            level: .trace,
            fields: fieldProbe.fields()
        )

        XCTAssertFalse(fieldProbe.wasEvaluated)
    }

    func testReleasingUnconsumedStreamDisablesItsSubscription() {
        let hub = ClamshellDiagnosticHub()
        createAndReleaseStream(on: hub)

        let fieldProbe = DiagnosticFieldProbe()
        hub.emit(
            .sourceOpened,
            level: .basic,
            fields: fieldProbe.fields()
        )

        XCTAssertFalse(fieldProbe.wasEvaluated)
    }

    func testStreamFinishesWhenHubIsReleased() async {
        let stream: AsyncStream<ClamshellDiagnosticEvent>
        do {
            let hub = ClamshellDiagnosticHub()
            stream = hub.stream(options: .init(level: .basic))
        }
        var iterator = stream.makeAsyncIterator()

        let event = await iterator.next()

        XCTAssertNil(event)
    }

    private func nextEvents(
        _ count: Int,
        from stream: AsyncStream<ClamshellDiagnosticEvent>
    ) async throws -> [ClamshellDiagnosticEvent] {
        var iterator = stream.makeAsyncIterator()
        var events: [ClamshellDiagnosticEvent] = []

        for _ in 0 ..< count {
            let nextEvent = await iterator.next()
            let event = try XCTUnwrap(nextEvent)
            events.append(event)
        }

        return events
    }

    private func createAndReleaseStream(on hub: ClamshellDiagnosticHub) {
        _ = hub.stream(options: .init(level: .basic))
    }
}

private final class DiagnosticFieldProbe {
    private(set) var wasEvaluated = false

    func fields() -> [String: ClamshellDiagnosticValue] {
        wasEvaluated = true
        return [:]
    }
}
