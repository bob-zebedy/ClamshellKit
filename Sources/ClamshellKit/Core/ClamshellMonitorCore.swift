import Dispatch
import Foundation

actor ClamshellMonitorCore {
    typealias Continuation = AsyncThrowingStream<ClamshellReading, any Error>.Continuation

    private static let nanosecondsPerSecond = 1000000000.0

    private struct Observer {
        let continuation: Continuation
        let maximumFrequency: Double?
        var lastValue: ClamshellReading?
        var lastDeliveryTime: UInt64?
    }

    private let source: any ClamshellAngleSource
    private let diagnostics: ClamshellDiagnosticHub

    private var observers: [UUID: Observer] = [:]
    private var isSourceOpen = false
    private var estimator: ClamshellMotionEstimator
    private var latestReading: ClamshellReading?
    private var pollingTask: Task<Void, Never>?
    private var pollingGeneration: UInt64 = 0
    private var lifecycleGeneration: UInt64 = 0

    init(
        source: any ClamshellAngleSource,
        diagnostics: ClamshellDiagnosticHub
    ) {
        self.source = source
        self.diagnostics = diagnostics
        estimator = ClamshellMotionEstimator(diagnostics: diagnostics)
    }

    var status: ClamshellStatus {
        get async {
            defer { closeSourceIfIdle() }

            do {
                _ = try readAngle()
                return .available
            } catch {
                let normalized = Self.normalize(error)
                emitFailure(operation: "status", error: normalized)
                return Self.status(for: normalized)
            }
        }
    }

    func angle() throws -> ClamshellAngle {
        defer { closeSourceIfIdle() }

        do {
            return try readAngle()
        } catch {
            let normalized = Self.normalize(error)
            emitFailure(operation: "angle", error: normalized)
            throw normalized
        }
    }

    func addObserver(
        id: UUID,
        generation: UInt64,
        options: ClamshellObservationOptions,
        continuation: Continuation
    ) {
        guard options.isValid else {
            continuation.finish(throwing: ClamshellError.invalidOptions)
            return
        }

        // Observation registration is asynchronous, so a stream created before
        // the latest explicit disconnect may reach the actor afterwards
        guard generation == lifecycleGeneration else {
            continuation.finish(throwing: ClamshellError.disconnected)
            return
        }

        guard !Task.isCancelled else {
            continuation.finish()
            return
        }

        let wasEmpty = observers.isEmpty
        observers[id] = Observer(
            continuation: continuation,
            maximumFrequency: options.maximumFrequency
        )

        do {
            if wasEmpty || !isSourceOpen {
                resetMotionState(reason: "observationStarted")
                let angle = try readFromSource()
                process(angle: angle)
            } else if let latestReading {
                deliver(latestReading, forcing: [id])
            }

            guard observers[id] != nil else {
                closeSourceIfIdle()
                return
            }

            restartPolling()
        } catch {
            observers.removeValue(forKey: id)
            closeSourceIfIdle()
            let normalized = Self.normalize(error)
            emitFailure(operation: "observer.add", error: normalized)
            continuation.finish(throwing: normalized)
        }
    }

    func disconnect(generation: UInt64) {
        guard generation > lifecycleGeneration else {
            return
        }

        lifecycleGeneration = generation
        finishObservers(
            throwing: .disconnected,
            resetReason: "explicitDisconnect"
        )
    }

    func removeObserver(id: UUID) {
        guard observers.removeValue(forKey: id) != nil else {
            return
        }

        if observers.isEmpty {
            stopPolling()
            resetMotionState(reason: "observationEnded")
            closeSource()
        } else {
            restartPolling()
        }
    }

    deinit {
        pollingTask?.cancel()
        source.close()
    }

    private func readAngle() throws -> ClamshellAngle {
        do {
            return try readFromSource()
        } catch {
            resetMotionState(reason: "readFailed")
            closeSource()
            throw error
        }
    }

    private func readFromSource() throws -> ClamshellAngle {
        if !isSourceOpen {
            try source.open()
            isSourceOpen = true
        }

        return try source.read()
    }

    private func closeSourceIfIdle() {
        guard observers.isEmpty else {
            return
        }

        resetMotionState(reason: "sourceIdle")
        closeSource()
    }

    private func closeSource() {
        guard isSourceOpen else {
            return
        }

        source.close()
        isSourceOpen = false
    }

    private func restartPolling() {
        guard !observers.isEmpty else {
            stopPolling()
            return
        }

        pollingGeneration &+= 1
        let generation = pollingGeneration
        let interval = pollingIntervalNanoseconds
        emitPollingConfiguration(interval: interval)

        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            await self?.poll(generation: generation, interval: interval)
        }
    }

    private func stopPolling() {
        pollingGeneration &+= 1
        pollingTask?.cancel()
        pollingTask = nil
    }

    private var pollingIntervalNanoseconds: UInt64 {
        let advertisedFrequency = source.maximumObservationFrequency
        let frequency =
            advertisedFrequency.isFinite && advertisedFrequency > 0
                ? advertisedFrequency
                : 20

        return Self.nanoseconds(for: frequency)
    }

    private func poll(generation: UInt64, interval initialInterval: UInt64) async {
        var interval = initialInterval

        while !Task.isCancelled, generation == pollingGeneration, !observers.isEmpty {
            do {
                try await Task.sleep(nanoseconds: interval)
            } catch {
                return
            }

            guard !Task.isCancelled, generation == pollingGeneration, !observers.isEmpty else {
                return
            }

            do {
                let angle = try readFromSource()
                process(angle: angle)
            } catch {
                resetMotionState(reason: "pollingReadFailed")

                do {
                    let angle = try await reconnectAndRead(generation: generation)
                    let reconnectedInterval = pollingIntervalNanoseconds
                    if reconnectedInterval != interval {
                        interval = reconnectedInterval
                        emitPollingConfiguration(interval: interval)
                    }
                    process(angle: angle)
                } catch is CancellationError {
                    return
                } catch {
                    guard generation == pollingGeneration, !observers.isEmpty else {
                        return
                    }

                    let normalized = Self.normalize(error)
                    emitFailure(operation: "polling", error: normalized)
                    finishObservers(throwing: normalized)
                    return
                }
            }
        }
    }

    private func emitPollingConfiguration(interval: UInt64) {
        let frequency = Self.nanosecondsPerSecond / Double(interval)

        diagnostics.emit(
            .pollingConfigured,
            level: .verbose,
            fields: [
                "frequency": .floatingPoint(frequency),
                "intervalNanoseconds": .unsignedInteger(interval),
                "observerCount": .integer(Int64(observers.count))
            ]
        )
    }

    private func reconnectAndRead(generation: UInt64) async throws -> ClamshellAngle {
        closeSource()

        let retryDelays: [UInt64] = [0, 250000000, 750000000]
        var lastError: ClamshellError = .unavailable

        for (attemptIndex, delay) in retryDelays.enumerated() {
            guard generation == pollingGeneration, !observers.isEmpty else {
                throw CancellationError()
            }

            let attempt = attemptIndex + 1
            diagnostics.emit(
                .reconnectAttempt,
                level: .basic,
                fields: [
                    "attempt": .integer(Int64(attempt)),
                    "delayNanoseconds": .unsignedInteger(delay)
                ]
            )

            if delay > 0 {
                try await Task.sleep(nanoseconds: delay)
            }

            guard generation == pollingGeneration, !observers.isEmpty else {
                throw CancellationError()
            }

            do {
                let angle = try readFromSource()
                diagnostics.emit(
                    .reconnectSucceeded,
                    level: .basic,
                    fields: ["attempt": .integer(Int64(attempt))]
                )
                return angle
            } catch {
                lastError = Self.normalize(error)
                closeSource()
                diagnostics.emit(
                    .reconnectFailed,
                    level: .basic,
                    fields: [
                        "attempt": .integer(Int64(attempt)),
                        "error": .string(lastError.diagnosticName),
                        "recoverable": .boolean(Self.isRecoverable(lastError))
                    ]
                )

                guard Self.isRecoverable(lastError) else {
                    throw lastError
                }
            }
        }

        throw lastError
    }

    private func deliver(
        _ value: ClamshellReading,
        forcing forcedObservers: Set<UUID> = []
    ) {
        let now = DispatchTime.now().uptimeNanoseconds
        var terminatedObservers: [UUID] = []
        var deliveredCount = 0
        var droppedCount = 0
        var throttledCount = 0
        var unchangedCount = 0

        for id in Array(observers.keys) {
            guard var observer = observers[id] else {
                continue
            }

            let isForced = forcedObservers.contains(id)
            guard isForced || observer.lastValue != value else {
                unchangedCount += 1
                continue
            }

            if !isForced,
               let maximumFrequency = observer.maximumFrequency,
               let lastDeliveryTime = observer.lastDeliveryTime {
                let minimumInterval = Self.nanoseconds(for: maximumFrequency)

                guard now &- lastDeliveryTime >= minimumInterval else {
                    throttledCount += 1
                    continue
                }
            }

            let result = observer.continuation.yield(value)
            if case .terminated = result {
                terminatedObservers.append(id)
                continue
            }

            deliveredCount += 1
            if case .dropped = result {
                droppedCount += 1
            }

            observer.lastValue = value
            observer.lastDeliveryTime = now
            observers[id] = observer
        }

        for id in terminatedObservers {
            observers.removeValue(forKey: id)
        }

        diagnostics.emit(
            .delivery,
            level: .verbose,
            fields: [
                "angle": .floatingPoint(value.angle.degrees),
                "deliveredCount": .integer(Int64(deliveredCount)),
                "droppedCount": .integer(Int64(droppedCount)),
                "observerCount": .integer(Int64(observers.count)),
                "terminatedCount": .integer(Int64(terminatedObservers.count)),
                "throttledCount": .integer(Int64(throttledCount)),
                "unchangedCount": .integer(Int64(unchangedCount))
            ]
        )

        if observers.isEmpty {
            stopPolling()
            resetMotionState(reason: "observationEnded")
            closeSource()
        }
    }

    private func finishObservers(
        throwing error: ClamshellError,
        resetReason: String = "observationFailed"
    ) {
        let continuations = observers.values.map(\.continuation)
        observers.removeAll()
        resetMotionState(reason: resetReason)
        stopPolling()
        closeSource()

        for continuation in continuations {
            continuation.finish(throwing: error)
        }
    }

    private func process(angle: ClamshellAngle) {
        let timestamp = DispatchTime.now().uptimeNanoseconds

        guard let reading = estimator.add(
            angle: angle,
            timestamp: timestamp
        ) else {
            latestReading = nil
            return
        }

        latestReading = reading
        deliver(reading)
    }

    private func resetMotionState(reason: String) {
        estimator.reset(reason: reason)
        latestReading = nil
    }

    private func emitFailure(
        operation: String,
        error: ClamshellError
    ) {
        var fields: [String: ClamshellDiagnosticValue] = [
            "error": .string(error.diagnosticName),
            "operation": .string(operation)
        ]

        if case let .systemError(code) = error {
            fields["systemCode"] = .integer(Int64(code))
        }

        diagnostics.emit(.failure, level: .basic, fields: fields)
    }

    private static func normalize(_ error: any Error) -> ClamshellError {
        if let error = error as? ClamshellError {
            return error
        }

        let nsError = error as NSError
        return .systemError(code: Int32(clamping: nsError.code))
    }

    private static func status(for error: ClamshellError) -> ClamshellStatus {
        switch error {
        case .notFound:
            .notFound
        case .unsupported, .invalidData:
            .unsupported
        case .accessDenied:
            .accessDenied
        case .unavailable,
             .disconnected,
             .invalidOptions,
             .systemError:
            .unavailable
        }
    }

    private static func isRecoverable(_ error: ClamshellError) -> Bool {
        switch error {
        case .unavailable, .notFound, .disconnected, .systemError:
            true
        case .unsupported, .accessDenied, .invalidData, .invalidOptions:
            false
        }
    }

    private static func nanoseconds(for frequency: Double) -> UInt64 {
        let nanoseconds = nanosecondsPerSecond / frequency

        guard nanoseconds.isFinite,
              nanoseconds < Double(UInt64.max) else {
            return .max
        }

        return max(1, UInt64(nanoseconds.rounded(.down)))
    }
}
