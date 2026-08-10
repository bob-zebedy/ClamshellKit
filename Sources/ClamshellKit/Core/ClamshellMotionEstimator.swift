/// Uses causal weighted regressions to estimate velocity from quantized angle
/// reports and then acceleration from the velocity estimates
struct ClamshellMotionEstimator {
    private struct Sample {
        let value: Double
        let timestamp: UInt64
    }

    private struct Regression {
        let slope: Double
        let meanTimestamp: UInt64
    }

    // Keep enough whole-degree samples for stable estimates while weighting
    // recent motion slightly more heavily to reduce causal-window lag
    private static let velocityWindowNanoseconds: UInt64 = 350000000
    private static let minimumVelocitySpanNanoseconds: UInt64 = 200000000
    private static let accelerationWindowNanoseconds: UInt64 = 400000000
    private static let minimumAccelerationSpanNanoseconds: UInt64 = 300000000
    private static let maximumGapNanoseconds: UInt64 = 1000000000
    private static let nanosecondsPerSecond = 1000000000.0
    private static let newestSampleRegressionWeight = 1.5

    // The current Apple profile reports whole degrees
    // Requiring two degrees of travel prevents one-degree quantization chatter from starting motion
    private static let motionEntryRange = 2.0
    private static let motionExitRange = 1.0
    private static let motionVelocityThreshold = 1.5
    private static let velocityDeadband = 0.75

    /// The shorter acceleration window exposes slightly more quantization
    /// noise and values below this reliable floor remain at rest
    private static let accelerationDeadband = 3.5

    private var angleSamples: [Sample] = []
    private var velocitySamples: [Sample] = []
    private var isMoving = false

    mutating func add(
        angle: ClamshellAngle,
        timestamp: UInt64
    ) -> ClamshellReading? {
        guard angle.degrees.isFinite else {
            reset()
            return nil
        }

        if let previous = angleSamples.last,
           timestamp <= previous.timestamp
           || timestamp - previous.timestamp > Self.maximumGapNanoseconds {
            reset()
        }

        angleSamples.append(
            Sample(value: angle.degrees, timestamp: timestamp)
        )
        trim(
            &angleSamples,
            to: Self.velocityWindowNanoseconds,
            endingAt: timestamp
        )

        guard hasMinimumSpan(
            angleSamples,
            Self.minimumVelocitySpanNanoseconds
        ), let velocityRegression = regression(of: angleSamples) else {
            return nil
        }

        updateMotionState(estimatedVelocity: velocityRegression.slope)

        let velocity = filteredVelocity(velocityRegression.slope)
        appendVelocity(
            velocity,
            timestamp: velocityRegression.meanTimestamp
        )

        guard hasMinimumSpan(
            velocitySamples,
            Self.minimumAccelerationSpanNanoseconds
        ), let accelerationRegression = regression(of: velocitySamples) else {
            return nil
        }

        guard isMoving else {
            return ClamshellReading(
                angle: angle,
                angularVelocity: 0,
                angularAcceleration: 0
            )
        }

        return ClamshellReading(
            angle: angle,
            angularVelocity: velocity,
            angularAcceleration: filteredAcceleration(
                accelerationRegression.slope
            )
        )
    }

    mutating func reset() {
        angleSamples.removeAll(keepingCapacity: true)
        velocitySamples.removeAll(keepingCapacity: true)
        isMoving = false
    }

    private mutating func updateMotionState(estimatedVelocity: Double) {
        guard let firstAngle = angleSamples.first?.value else {
            isMoving = false
            return
        }

        var minimumAngle = firstAngle
        var maximumAngle = firstAngle

        for sample in angleSamples.dropFirst() {
            minimumAngle = min(minimumAngle, sample.value)
            maximumAngle = max(maximumAngle, sample.value)
        }

        let angleRange = maximumAngle - minimumAngle

        if isMoving {
            if angleRange <= Self.motionExitRange,
               abs(estimatedVelocity) < Self.motionVelocityThreshold {
                isMoving = false
            }
        } else if angleRange >= Self.motionEntryRange,
                  abs(estimatedVelocity) >= Self.motionVelocityThreshold {
            isMoving = true
        }
    }

    private mutating func appendVelocity(
        _ velocity: Double,
        timestamp: UInt64
    ) {
        let sample = Sample(value: velocity, timestamp: timestamp)

        if velocitySamples.last?.timestamp == timestamp {
            velocitySamples[velocitySamples.count - 1] = sample
        } else {
            velocitySamples.append(sample)
        }

        trim(
            &velocitySamples,
            to: Self.accelerationWindowNanoseconds,
            endingAt: timestamp
        )
    }

    private func regression(of samples: [Sample]) -> Regression? {
        guard samples.count >= 2,
              let firstTimestamp = samples.first?.timestamp,
              let lastTimestamp = samples.last?.timestamp,
              lastTimestamp > firstTimestamp else {
            return nil
        }

        let timestampSpan = Double(lastTimestamp - firstTimestamp)
        let weightRange = Self.newestSampleRegressionWeight - 1
        let weightScale = weightRange / timestampSpan
        var totalWeight = 0.0
        var weightedTime = 0.0
        var weightedValue = 0.0

        for sample in samples {
            let sampleWeight = regressionWeight(
                for: sample.timestamp,
                after: firstTimestamp,
                scale: weightScale
            )
            totalWeight += sampleWeight
            weightedTime += sampleWeight
                * seconds(sample.timestamp - firstTimestamp)
            weightedValue += sampleWeight * sample.value
        }

        let meanTime = weightedTime / totalWeight
        let meanValue = weightedValue / totalWeight

        var timeVariance = 0.0
        var covariance = 0.0

        for sample in samples {
            let sampleWeight = regressionWeight(
                for: sample.timestamp,
                after: firstTimestamp,
                scale: weightScale
            )
            let centeredTime = seconds(sample.timestamp - firstTimestamp)
                - meanTime
            timeVariance += sampleWeight * centeredTime * centeredTime
            covariance += sampleWeight
                * centeredTime
                * (sample.value - meanValue)
        }

        guard timeVariance > 0 else {
            return nil
        }

        let slope = covariance / timeVariance
        guard slope.isFinite else {
            return nil
        }

        let meanOffset = UInt64(
            (meanTime * Self.nanosecondsPerSecond).rounded()
        )

        return Regression(
            slope: slope,
            meanTimestamp: firstTimestamp + meanOffset
        )
    }

    private func regressionWeight(
        for timestamp: UInt64,
        after firstTimestamp: UInt64,
        scale: Double
    ) -> Double {
        1 + Double(timestamp - firstTimestamp) * scale
    }

    private func hasMinimumSpan(
        _ samples: [Sample],
        _ minimumSpan: UInt64
    ) -> Bool {
        guard samples.count >= 2,
              let firstTimestamp = samples.first?.timestamp,
              let lastTimestamp = samples.last?.timestamp else {
            return false
        }

        return lastTimestamp - firstTimestamp >= minimumSpan
    }

    private func filteredVelocity(_ velocity: Double) -> Double {
        guard isMoving, abs(velocity) >= Self.velocityDeadband else {
            return 0
        }

        return velocity
    }

    private func filteredAcceleration(_ acceleration: Double) -> Double {
        abs(acceleration) < Self.accelerationDeadband ? 0 : acceleration
    }

    private func seconds(_ nanoseconds: UInt64) -> Double {
        Double(nanoseconds) / Self.nanosecondsPerSecond
    }

    private func trim(
        _ samples: inout [Sample],
        to window: UInt64,
        endingAt timestamp: UInt64
    ) {
        let removalCount = samples.prefix {
            timestamp - $0.timestamp > window
        }.count

        if removalCount > 0 {
            samples.removeFirst(removalCount)
        }
    }
}
