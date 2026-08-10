import Foundation

/// Reads and observes the clamshell state of supported Mac notebooks
public final class ClamshellMonitor: Sendable {
    private let core: ClamshellMonitorCore

    public init() {
        core = ClamshellMonitorCore(source: IOKitHIDSource())
    }

    init(source: any ClamshellAngleSource) {
        core = ClamshellMonitorCore(source: source)
    }

    /// The device's current availability
    ///
    /// Reading this property probes the device and reflects the current
    /// machine instead of a cached startup value
    public var status: ClamshellStatus {
        get async {
            await core.status
        }
    }

    /// Returns the current angle using one sensor read
    public func angle() async throws -> ClamshellAngle {
        try await core.angle()
    }

    /// Returns the current angle and estimated rotational motion
    ///
    /// This method collects a short sequence of angle samples before returning
    public func reading() async throws -> ClamshellReading {
        let stream = observe(options: .init(maximumFrequency: nil))
        var iterator = stream.makeAsyncIterator()

        guard let reading = try await iterator.next() else {
            if Task.isCancelled {
                throw CancellationError()
            }

            throw ClamshellError.unavailable
        }

        return reading
    }

    /// Returns a stream of angle and estimated rotational-motion readings
    ///
    /// Multiple streams share one device connection
    ///
    /// Values are coalesced to the newest pending value when a consumer cannot keep up
    public func observe(
        options: ClamshellObservationOptions = .default
    ) -> AsyncThrowingStream<ClamshellReading, any Error> {
        guard options.isValid else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: ClamshellError.invalidOptions)
            }
        }

        let id = UUID()
        let core = core

        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let registration = Task {
                await core.addObserver(
                    id: id,
                    options: options,
                    continuation: continuation
                )
            }

            continuation.onTermination = { @Sendable [weak core] _ in
                registration.cancel()
                guard let core else {
                    return
                }

                Task {
                    await core.removeObserver(id: id)
                }
            }
        }
    }
}
