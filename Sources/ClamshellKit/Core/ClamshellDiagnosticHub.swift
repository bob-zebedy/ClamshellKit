import Dispatch
import Foundation

/// Delivers diagnostics without involving the sensor actor or blocking its polling loop
final class ClamshellDiagnosticHub: @unchecked Sendable {
    typealias Continuation = AsyncStream<ClamshellDiagnosticEvent>.Continuation

    private struct Observer {
        let level: ClamshellDiagnosticsLevel
        let continuation: Continuation
    }

    private static let bufferCapacity = 256

    private let lock = NSLock()
    private var observers: [UUID: Observer] = [:]

    deinit {
        let continuations = lock.withLock {
            let continuations = observers.values.map(\.continuation)
            observers.removeAll()
            return continuations
        }

        for continuation in continuations {
            continuation.finish()
        }
    }

    func stream(
        options: ClamshellDiagnosticsOptions
    ) -> AsyncStream<ClamshellDiagnosticEvent> {
        guard options.level != .off else {
            return AsyncStream { continuation in
                continuation.finish()
            }
        }

        let id = UUID()

        return AsyncStream(
            bufferingPolicy: .bufferingNewest(Self.bufferCapacity)
        ) { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }

            lock.withLock {
                observers[id] = Observer(
                    level: options.level,
                    continuation: continuation
                )
            }

            continuation.onTermination = { @Sendable [weak self] _ in
                self?.removeObserver(id: id)
            }
        }
    }

    func emit(
        _ kind: ClamshellDiagnosticEvent.Kind,
        level: ClamshellDiagnosticsLevel,
        fields: @autoclosure () -> [String: ClamshellDiagnosticValue]
    ) {
        guard level != .off else {
            return
        }

        let targets = lock.withLock {
            observers.compactMap { id, observer in
                observer.level >= level ? (id, observer.continuation) : nil
            }
        }

        guard !targets.isEmpty else {
            return
        }

        let event = ClamshellDiagnosticEvent(
            level: level,
            uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
            kind: kind,
            fields: fields()
        )
        var terminatedIDs: [UUID] = []

        for (id, continuation) in targets {
            if case .terminated = continuation.yield(event) {
                terminatedIDs.append(id)
            }
        }

        guard !terminatedIDs.isEmpty else {
            return
        }

        lock.withLock {
            for id in terminatedIDs {
                observers.removeValue(forKey: id)
            }
        }
    }

    private func removeObserver(id: UUID) {
        lock.withLock {
            _ = observers.removeValue(forKey: id)
        }
    }
}

extension ClamshellError {
    var diagnosticName: String {
        switch self {
        case .unavailable:
            "unavailable"
        case .notFound:
            "notFound"
        case .unsupported:
            "unsupported"
        case .accessDenied:
            "accessDenied"
        case .disconnected:
            "disconnected"
        case .invalidData:
            "invalidData"
        case .invalidOptions:
            "invalidOptions"
        case .systemError:
            "systemError"
        }
    }
}
