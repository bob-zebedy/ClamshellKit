import Dispatch
import Foundation

actor ClamshellMonitorCore {
    typealias Continuation = AsyncThrowingStream<ClamshellAngle, any Error>.Continuation

    private struct Observer {
        let continuation: Continuation
        let maximumFrequency: Double?
        var lastValue: ClamshellAngle?
        var lastDeliveryTime: UInt64?
    }

    private let source: any ClamshellAngleSource

    private var observers: [UUID: Observer] = [:]
    private var isSourceOpen = false
    private var latestValue: ClamshellAngle?
    private var pollingTask: Task<Void, Never>?
    private var pollingGeneration: UInt64 = 0

    init(source: any ClamshellAngleSource) {
        self.source = source
    }

    var status: ClamshellStatus {
        get async {
            do {
                _ = try readAndPublish()
                closeSourceIfIdle()
                return .available
            } catch {
                closeSourceIfIdle()
                return Self.status(for: Self.normalize(error))
            }
        }
    }

    func read() throws -> ClamshellAngle {
        do {
            let value = try readAndPublish()
            closeSourceIfIdle()
            return value
        } catch {
            closeSourceIfIdle()
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
            if wasEmpty || latestValue == nil || !isSourceOpen {
                let value = try readFromSource()
                latestValue = value
                deliver(value, forcing: [id])
            } else if let latestValue {
                deliver(latestValue, forcing: [id])
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
            latestValue = nil
            closeSource()
        } else {
            restartPolling()
        }
    }

    deinit {
        pollingTask?.cancel()
        source.close()
    }

    private func readAndPublish() throws -> ClamshellAngle {
        do {
            let value = try readFromSource()
            latestValue = value
            deliver(value)
            return value
        } catch {
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

        latestValue = nil
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
        let sourceFrequency =
            advertisedFrequency.isFinite && advertisedFrequency > 0
                ? advertisedFrequency
                : 20
        let requestedFrequency =
            observers.values
                .map { $0.maximumFrequency ?? sourceFrequency }
                .max() ?? sourceFrequency
        let frequency = min(sourceFrequency, requestedFrequency)

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
                let value = try readFromSource()
                latestValue = value
                deliver(value)
            } catch {
                do {
                    let value = try await reconnectAndRead(generation: generation)
                    latestValue = value
                    deliver(value)
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
        _ value: ClamshellAngle,
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
            latestValue = nil
            closeSource()
        }
    }

    private func finishObservers(throwing error: ClamshellError) {
        let continuations = observers.values.map(\.continuation)
        observers.removeAll()
        latestValue = nil
        stopPolling()
        closeSource()

        for continuation in continuations {
            continuation.finish(throwing: error)
        }
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
