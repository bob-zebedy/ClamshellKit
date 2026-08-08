@testable import ClamshellKit
import Foundation

final class TestAngleSource: ClamshellAngleSource, @unchecked Sendable {
    struct Snapshot: Equatable, Sendable {
        let openCount: Int
        let readCount: Int
        let closeCount: Int
    }

    let maximumObservationFrequency: Double

    private let lock = NSLock()
    private var angle: ClamshellAngle
    private let openError: ClamshellError?
    private let readError: ClamshellError?
    private var pendingReadFailures: (count: Int, error: ClamshellError)?
    private var isOpen = false
    private var openCount = 0
    private var readCount = 0
    private var closeCount = 0

    init(
        angle: Double,
        maximumObservationFrequency: Double = 60,
        openError: ClamshellError? = nil,
        readError: ClamshellError? = nil
    ) {
        self.angle = ClamshellAngle(degrees: angle)
        self.maximumObservationFrequency = maximumObservationFrequency
        self.openError = openError
        self.readError = readError
    }

    var snapshot: Snapshot {
        withLock {
            Snapshot(
                openCount: openCount,
                readCount: readCount,
                closeCount: closeCount
            )
        }
    }

    func setAngle(_ degrees: Double) {
        withLock {
            angle = ClamshellAngle(degrees: degrees)
        }
    }

    func failNextReads(_ count: Int, with error: ClamshellError) {
        withLock {
            pendingReadFailures = (count, error)
        }
    }

    func waitForSnapshot(
        matching predicate: @Sendable (Snapshot) -> Bool
    ) async throws -> Snapshot {
        for _ in 0 ..< 50 {
            let snapshot = snapshot
            if predicate(snapshot) {
                return snapshot
            }

            try await Task.sleep(nanoseconds: 10000000)
        }

        return snapshot
    }

    func open() throws {
        try withLock {
            openCount += 1
            if let openError {
                throw openError
            }

            isOpen = true
        }
    }

    func close() {
        withLock {
            guard isOpen else {
                return
            }

            closeCount += 1
            isOpen = false
        }
    }

    func read() throws -> ClamshellAngle {
        try withLock {
            readCount += 1
            if var failure = pendingReadFailures, failure.count > 0 {
                failure.count -= 1
                if failure.count == 0 {
                    pendingReadFailures = nil
                } else {
                    pendingReadFailures = failure
                }
                throw failure.error
            }
            if let readError {
                throw readError
            }
            guard isOpen else {
                throw ClamshellError.disconnected
            }

            return angle
        }
    }

    private func withLock<Result>(
        _ operation: () throws -> Result
    ) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }

        return try operation()
    }
}
