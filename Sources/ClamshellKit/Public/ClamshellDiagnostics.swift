import Foundation

/// Controls how much diagnostic information ClamshellKit emits
public enum ClamshellDiagnosticsLevel: Int, Sendable, Equatable, Comparable {
    /// Disables diagnostic events
    case off = 0

    /// Emits lifecycle, discovery, profile-selection, reconnection, and error events
    case basic = 1

    /// Adds device descriptors, profile evaluations, decoding, polling, and delivery events
    case verbose = 2

    /// Adds raw reports and per-sample motion-estimator events
    case trace = 3

    public static func < (
        lhs: ClamshellDiagnosticsLevel,
        rhs: ClamshellDiagnosticsLevel
    ) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Options that control one diagnostic event stream
public struct ClamshellDiagnosticsOptions: Sendable, Equatable {
    /// The default diagnostic configuration, which emits basic events
    public static let `default` = Self()

    /// The maximum detail included in this stream
    public var level: ClamshellDiagnosticsLevel

    public init(level: ClamshellDiagnosticsLevel = .basic) {
        self.level = level
    }
}

/// A structured value attached to a diagnostic event
public enum ClamshellDiagnosticValue: Sendable, Equatable, CustomStringConvertible {
    case string(String)
    case integer(Int64)
    case unsignedInteger(UInt64)
    case floatingPoint(Double)
    case boolean(Bool)
    case bytes([UInt8])

    public var description: String {
        switch self {
        case let .string(value):
            String(reflecting: value)
        case let .integer(value):
            String(value)
        case let .unsignedInteger(value):
            String(value)
        case let .floatingPoint(value):
            String(value)
        case let .boolean(value):
            String(value)
        case let .bytes(value):
            value.map { String(format: "%02X", $0) }.joined(separator: " ")
        }
    }
}

/// A diagnostic event emitted alongside normal clamshell readings
public struct ClamshellDiagnosticEvent: Sendable, Equatable, CustomStringConvertible {
    public enum Kind: String, Sendable, Equatable {
        case sourceOpening = "source.opening"
        case sourceOpened = "source.opened"
        case sourceClosed = "source.closed"
        case deviceDiscovery = "device.discovery"
        case deviceCandidate = "device.candidate"
        case hidElement = "hid.element"
        case profileEvaluated = "profile.evaluated"
        case profileSelected = "profile.selected"
        case reportRead = "report.read"
        case rawReport = "report.raw"
        case angleDecoded = "angle.decoded"
        case pollingConfigured = "polling.configured"
        case delivery = "reading.delivery"
        case reconnectAttempt = "reconnect.attempt"
        case reconnectSucceeded = "reconnect.succeeded"
        case reconnectFailed = "reconnect.failed"
        case estimatorSample = "estimator.sample"
        case estimatorVelocity = "estimator.velocity"
        case estimatorAcceleration = "estimator.acceleration"
        case estimatorReset = "estimator.reset"
        case motionStateChanged = "estimator.motion-state-changed"
        case failure
    }

    /// The minimum level required to receive this event
    public let level: ClamshellDiagnosticsLevel

    /// A monotonic timestamp suitable for ordering events within the current boot
    public let uptimeNanoseconds: UInt64

    public let kind: Kind
    public let fields: [String: ClamshellDiagnosticValue]

    public init(
        level: ClamshellDiagnosticsLevel,
        uptimeNanoseconds: UInt64,
        kind: Kind,
        fields: [String: ClamshellDiagnosticValue] = [:]
    ) {
        self.level = level
        self.uptimeNanoseconds = uptimeNanoseconds
        self.kind = kind
        self.fields = fields
    }

    public var description: String {
        let details = fields
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")

        if details.isEmpty {
            return "[ClamshellKit][\(kind.rawValue)]"
        }

        return "[ClamshellKit][\(kind.rawValue)] \(details)"
    }
}
