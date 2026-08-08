import Foundation

/// Reads and observes the display angle of supported Mac notebooks.
public final class ClamshellMonitor: Sendable {
    private let core: ClamshellMonitorCore

    public init() {
        core = ClamshellMonitorCore(source: IOKitHIDSource())
    }

    init(source: any ClamshellAngleSource) {
        core = ClamshellMonitorCore(source: source)
    }

    /// The device's current availability.
    ///
    /// Reading this property probes the device, so the result reflects the
    /// current machine rather than a cached startup value.
    public var status: ClamshellStatus {
        get async {
            await core.status
        }
    }

    /// Returns one angle reading.
    public func read() async throws -> ClamshellAngle {
        try await core.read()
    }

    /// Returns a stream containing the initial angle followed by angle changes.
    ///
    /// Multiple streams share one device connection. Values are coalesced to
    /// the newest pending value when a consumer cannot keep up.
    public func observe(
        options: ClamshellObservationOptions = .default
    ) -> AsyncThrowingStream<ClamshellAngle, any Error> {
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
