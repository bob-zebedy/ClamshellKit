import Dispatch
import Foundation

actor ClamshellMonitorCore {
    typealias Continuation = AsyncThrowingStream<ClamshellReading, any Error>.Continuation

    private struct Observer {
        let continuation: Continuation
        let maximumFrequency: Double?
        var lastValue: ClamshellReading?
        var lastDeliveryTime: UInt64?
    }

    private let source: any ClamshellAngleSource

    private var observers: [UUID: Observer] = [:]
    private var isSourceOpen = false
    private var estimator = ClamshellMotionEstimator()
    private var latestReading: ClamshellReading?
    private var pollingTask: Task<Void, Never>?
    private var pollingGeneration: UInt64 = 0

    init(source: any ClamshellAngleSource) {
        self.source = source
    }

    var status: ClamshellStatus {
        get async {
            defer { closeSourceIfIdle() }

            do {
                _ = try readAngle()
                return .available
            } catch {
                return Self.status(for: Self.normalize(error))
            }
        }
    }

    func angle() throws -> ClamshellAngle {
        defer { closeSourceIfIdle() }

        do {
            return try readAngle()
        } catch {
            throw Self.normalize(error)
        }
    }

    func addObserver(
        id: UUID,
        options: ClamshellObservationOptions,
        continuation: Continuation
    ) {
        guard options.isValid else {
            continuation.finish(throwing: ClamshellError.invalidOptions)
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
                resetMotionState()
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
            continuation.finish(throwing: Self.normalize(error))
        }
    }

    func removeObserver(id: UUID) {
        guard observers.removeValue(forKey: id) != nil else {
            return
        }

        if observers.isEmpty {
            stopPolling()
            resetMotionState()
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
            resetMotionState()
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

        resetMotionState()
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

    private func poll(generation: UInt64, interval: UInt64) async {
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
                resetMotionState()

                do {
                    let angle = try await reconnectAndRead(generation: generation)
                    process(angle: angle)
                } catch is CancellationError {
                    return
                } catch {
                    guard generation == pollingGeneration, !observers.isEmpty else {
                        return
                    }

                    finishObservers(throwing: Self.normalize(error))
                    return
                }
            }
        }
    }

    private func reconnectAndRead(generation: UInt64) async throws -> ClamshellAngle {
        closeSource()

        let retryDelays: [UInt64] = [0, 250000000, 750000000]
        var lastError: ClamshellError = .unavailable

        for delay in retryDelays {
            guard generation == pollingGeneration, !observers.isEmpty else {
                throw CancellationError()
            }

            if delay > 0 {
                try await Task.sleep(nanoseconds: delay)
            }

            guard generation == pollingGeneration, !observers.isEmpty else {
                throw CancellationError()
            }

            do {
                return try readFromSource()
            } catch {
                lastError = Self.normalize(error)
                closeSource()

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

        for id in Array(observers.keys) {
            guard var observer = observers[id] else {
                continue
            }

            let isForced = forcedObservers.contains(id)
            guard isForced || observer.lastValue != value else {
                continue
            }

            if !isForced,
               let maximumFrequency = observer.maximumFrequency,
               let lastDeliveryTime = observer.lastDeliveryTime {
                let minimumInterval = Self.nanoseconds(for: maximumFrequency)

                guard now &- lastDeliveryTime >= minimumInterval else {
                    continue
                }
            }

            if case .terminated = observer.continuation.yield(value) {
                terminatedObservers.append(id)
                continue
            }

            observer.lastValue = value
            observer.lastDeliveryTime = now
            observers[id] = observer
        }

        for id in terminatedObservers {
            observers.removeValue(forKey: id)
        }

        if observers.isEmpty {
            stopPolling()
            resetMotionState()
            closeSource()
        }
    }

    private func finishObservers(throwing error: ClamshellError) {
        let continuations = observers.values.map(\.continuation)
        observers.removeAll()
        resetMotionState()
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

    private func resetMotionState() {
        estimator.reset()
        latestReading = nil
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
        let nanoseconds = 1000000000 / frequency

        guard nanoseconds.isFinite,
              nanoseconds < Double(UInt64.max) else {
            return .max
        }

        return max(1, UInt64(nanoseconds.rounded(.down)))
    }
}
