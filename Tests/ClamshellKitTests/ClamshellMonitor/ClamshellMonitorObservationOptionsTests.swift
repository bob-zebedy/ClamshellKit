@testable import ClamshellKit
import XCTest

final class ClamshellMonitorObservationOptionsTests: XCTestCase {
    func testDefaultMaximumFrequencyIsThirtyHertz() {
        XCTAssertEqual(
            ClamshellObservationOptions.default.maximumFrequency,
            30
        )
        XCTAssertEqual(
            ClamshellObservationOptions().maximumFrequency,
            30
        )
    }

    func testZeroMaximumFrequencyFailsWithoutOpeningSource() async {
        await assertRejectedMaximumFrequency(0)
    }

    func testNonFiniteMaximumFrequenciesFailWithoutOpeningSource() async {
        for frequency in [Double.nan, .infinity, -.infinity] {
            await assertRejectedMaximumFrequency(frequency)
        }
    }

    func testPositiveFiniteMaximumFrequencyIsAccepted() async throws {
        let source = TestAngleSource(angle: 15)
        let monitor = ClamshellMonitor(source: source)
        let stream = monitor.observe(
            options: .init(maximumFrequency: .leastNonzeroMagnitude)
        )
        var iterator = stream.makeAsyncIterator()

        let initialReading = try await iterator.next()

        XCTAssertEqual(initialReading?.angle, ClamshellAngle(degrees: 15))
        XCTAssertEqual(source.snapshot.openCount, 1)
    }
}

private func assertRejectedMaximumFrequency(
    _ frequency: Double,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    let source = TestAngleSource(angle: 0)
    let monitor = ClamshellMonitor(source: source)
    let stream = monitor.observe(
        options: .init(maximumFrequency: frequency)
    )
    var iterator = stream.makeAsyncIterator()

    do {
        _ = try await iterator.next()
        XCTFail("Expected invalidOptions for \(frequency)", file: file, line: line)
    } catch {
        XCTAssertEqual(error as? ClamshellError, .invalidOptions, file: file, line: line)
    }

    XCTAssertEqual(source.snapshot.openCount, 0, file: file, line: line)
}
