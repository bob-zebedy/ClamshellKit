@testable import ClamshellKit
import XCTest

final class ClamshellMotionEstimatorTests: XCTestCase {
    private let nanosecondsPerSecond = 1000000000.0

    func testRequiresSufficientTimeForBothRegressionWindows() throws {
        var estimator = ClamshellMotionEstimator()

        for index in 0 ... 5 {
            XCTAssertNil(
                estimator.add(
                    angle: ClamshellAngle(degrees: 30),
                    timestamp: UInt64(index) * 100000000
                )
            )
        }

        let reading = try XCTUnwrap(
            estimator.add(
                angle: ClamshellAngle(degrees: 30),
                timestamp: 600000000
            )
        )

        XCTAssertEqual(reading.angle, ClamshellAngle(degrees: 30))
        XCTAssertEqual(reading.angularVelocity, 0)
        XCTAssertEqual(reading.angularAcceleration, 0)
    }

    func testVelocityRespondsToMotionWithinBalancedLatency() throws {
        let estimates = estimate(duration: 2) { time in
            time <= 1
                ? 100
                : (100 + 30 * (time - 1)).rounded()
        }
        let response = try XCTUnwrap(
            estimates.first {
                $0.time >= 1 && $0.reading.angularVelocity >= 27
            }
        )

        XCTAssertLessThanOrEqual(response.time - 1, 0.3)
    }

    func testAccelerationRespondsWithinBalancedLatency() throws {
        let estimates = estimate(duration: 3) { time in
            if time <= 1 {
                return (100 + 10 * time).rounded()
            }

            let acceleratingTime = time - 1
            return (
                110
                    + 10 * acceleratingTime
                    + 10 * acceleratingTime * acceleratingTime
            ).rounded()
        }

        let response = try XCTUnwrap(
            estimates.first {
                $0.time >= 1
                    && $0.reading.angularAcceleration >= 10
            }
        )

        XCTAssertLessThanOrEqual(response.time - 1, 0.4)
    }

    func testStationaryOneDegreeJitterRemainsAtRest() {
        let estimates = estimate(duration: 2) { time in
            Int((time * 60).rounded()).isMultiple(of: 2) ? 123 : 124
        }

        XCTAssertFalse(estimates.isEmpty)

        for estimate in estimates {
            XCTAssertEqual(estimate.reading.angularVelocity, 0)
            XCTAssertEqual(estimate.reading.angularAcceleration, 0)
        }
    }

    func testEstimatesQuantizedOpeningVelocityWithoutAccelerationSpikes() {
        let estimates = steadyEstimates(velocity: 10)

        XCTAssertFalse(estimates.isEmpty)

        for estimate in estimates {
            XCTAssertEqual(
                estimate.reading.angularVelocity,
                10,
                accuracy: 0.5
            )
            XCTAssertEqual(estimate.reading.angularAcceleration, 0)
        }
    }

    func testEstimatesQuantizedClosingVelocityWithoutAccelerationSpikes() {
        let estimates = steadyEstimates(velocity: -10)

        XCTAssertFalse(estimates.isEmpty)

        for estimate in estimates {
            XCTAssertEqual(
                estimate.reading.angularVelocity,
                -10,
                accuracy: 0.5
            )
            XCTAssertEqual(estimate.reading.angularAcceleration, 0)
        }
    }

    func testEstimatesSlowQuantizedMotion() {
        let estimates = steadyEstimates(velocity: 5)

        XCTAssertFalse(estimates.isEmpty)

        for estimate in estimates {
            XCTAssertEqual(
                estimate.reading.angularVelocity,
                5,
                accuracy: 1
            )
            XCTAssertEqual(estimate.reading.angularAcceleration, 0)
        }
    }

    func testEstimatesQuantizedAngularAcceleration() throws {
        let estimates = estimate(duration: 2) { time in
            (30 + 5 * time + 5 * time * time).rounded()
        }
        let reading = try XCTUnwrap(estimates.last?.reading)

        XCTAssertGreaterThan(reading.angularVelocity, 0)
        XCTAssertEqual(reading.angularAcceleration, 10, accuracy: 2)
    }

    func testEstimatesNegativeQuantizedAngularAcceleration() throws {
        let estimates = estimate(duration: 2) { time in
            (150 - 5 * time - 5 * time * time).rounded()
        }
        let reading = try XCTUnwrap(estimates.last?.reading)

        XCTAssertLessThan(reading.angularVelocity, 0)
        XCTAssertEqual(reading.angularAcceleration, -10, accuracy: 2)
    }

    func testHandlesIrregularSamplingIntervals() throws {
        var estimator = ClamshellMotionEstimator()
        let intervals: [UInt64] = [12000000, 19000000, 15000000, 22000000]
        var timestamp: UInt64 = 0
        var index = 0
        var reading: ClamshellReading?

        while timestamp <= 2500000000 {
            let time = Double(timestamp) / nanosecondsPerSecond
            reading = estimator.add(
                angle: ClamshellAngle(
                    degrees: (40 + 12 * time).rounded()
                ),
                timestamp: timestamp
            ) ?? reading
            timestamp += intervals[index % intervals.count]
            index += 1
        }

        let finalReading = try XCTUnwrap(reading)
        XCTAssertEqual(finalReading.angularVelocity, 12, accuracy: 1)
        XCTAssertEqual(finalReading.angularAcceleration, 0)
    }

    func testNonMonotonicTimestampResetsEstimator() {
        var estimator = ClamshellMotionEstimator()
        let lastTimestamp = warmUp(&estimator)

        XCTAssertNil(
            estimator.add(
                angle: ClamshellAngle(degrees: 30),
                timestamp: lastTimestamp
            )
        )

        var reading: ClamshellReading?
        for index in 1 ... 6 {
            reading = estimator.add(
                angle: ClamshellAngle(degrees: 30),
                timestamp: lastTimestamp + UInt64(index) * 100000000
            )
        }

        XCTAssertNotNil(reading)
    }

    func testLongSamplingGapResetsEstimator() {
        var estimator = ClamshellMotionEstimator()
        let lastTimestamp = warmUp(&estimator)

        XCTAssertNil(
            estimator.add(
                angle: ClamshellAngle(degrees: 30),
                timestamp: lastTimestamp + 2000000000
            )
        )
    }

    private func steadyEstimates(
        velocity: Double
    ) -> [(time: Double, reading: ClamshellReading)] {
        estimate(duration: 2) { time in
            (100 + velocity * time).rounded()
        }.filter { $0.time >= 1.5 }
    }

    private func estimate(
        duration: Double,
        angle: (Double) -> Double
    ) -> [(time: Double, reading: ClamshellReading)] {
        var estimator = ClamshellMotionEstimator()
        var estimates: [(time: Double, reading: ClamshellReading)] = []
        let sampleCount = Int((duration * 60).rounded())

        for index in 0 ... sampleCount {
            let time = Double(index) / 60
            let timestamp = UInt64(
                (time * nanosecondsPerSecond).rounded()
            )

            if let reading = estimator.add(
                angle: ClamshellAngle(degrees: angle(time)),
                timestamp: timestamp
            ) {
                estimates.append((time, reading))
            }
        }

        return estimates
    }

    private func warmUp(
        _ estimator: inout ClamshellMotionEstimator
    ) -> UInt64 {
        var reading: ClamshellReading?
        var timestamp: UInt64 = 0

        for index in 0 ... 6 {
            timestamp = UInt64(index) * 100000000
            reading = estimator.add(
                angle: ClamshellAngle(degrees: 30),
                timestamp: timestamp
            )
        }

        XCTAssertNotNil(reading)
        return timestamp
    }
}
