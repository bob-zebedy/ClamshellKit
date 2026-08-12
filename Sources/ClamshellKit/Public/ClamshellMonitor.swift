import Foundation

/// Reads and observes the clamshell state of supported Mac notebooks
public final class ClamshellMonitor: Sendable {
    private let core: ClamshellMonitorCore
    private let diagnosticHub: ClamshellDiagnosticHub
    private let lifecycle = ClamshellMonitorLifecycle()

    public init() {
        let diagnosticHub = ClamshellDiagnosticHub()
        self.diagnosticHub = diagnosticHub
        core = ClamshellMonitorCore(
            source: IOKitHIDSource(diagnostics: diagnosticHub),
            diagnostics: diagnosticHub
        )
    }

    init(source: any ClamshellAngleSource) {
        let diagnosticHub = ClamshellDiagnosticHub()
        self.diagnosticHub = diagnosticHub
        core = ClamshellMonitorCore(
            source: source,
            diagnostics: diagnosticHub
        )
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

    /// Closes the current sensor connection and releases its resources
    ///
    /// Active observations and pending calls to ``reading()`` fail with
    /// ``ClamshellError/disconnected``. The monitor remains reusable, and the
    /// next data operation opens a new connection lazily.
    public func disconnect() async {
        let generation = lifecycle.beginDisconnection()
        await core.disconnect(generation: generation)
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
        let generation = lifecycle.currentGeneration

        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let registration = Task {
                await core.addObserver(
                    id: id,
                    generation: generation,
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

    /// Returns an independent stream of opt-in diagnostic events
    ///
    /// Creating this stream enables diagnostics at the requested level
    /// Cancelling or releasing it disables that subscription
    /// Diagnostic subscriptions never open or keep the sensor connection alive
    public func observeDiagnostics(
        options: ClamshellDiagnosticsOptions = .default
    ) -> AsyncStream<ClamshellDiagnosticEvent> {
        diagnosticHub.stream(options: options)
    }
}

/// Invalidates observation registrations synchronously when disconnection begins
private final class ClamshellMonitorLifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0

    var currentGeneration: UInt64 {
        lock.withLock { generation }
    }

    func beginDisconnection() -> UInt64 {
        lock.withLock {
            generation &+= 1
            return generation
        }
    }
}
