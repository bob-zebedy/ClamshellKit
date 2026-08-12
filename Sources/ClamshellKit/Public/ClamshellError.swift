import Foundation

/// Errors produced while accessing or observing the clamshell sensor
public enum ClamshellError: Error, LocalizedError, Sendable, Equatable {
    case unavailable
    case notFound
    case unsupported
    case accessDenied
    case disconnected
    case invalidData
    case invalidOptions
    case systemError(code: Int32)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "The clamshell angle is currently unavailable"
        case .notFound:
            "No compatible clamshell-angle device was found"
        case .unsupported:
            "The detected clamshell-angle device is not supported"
        case .accessDenied:
            "macOS denied access to the clamshell-angle device"
        case .disconnected:
            "The clamshell-angle device was disconnected or its connection was closed"
        case .invalidData:
            "The clamshell-angle device returned invalid data"
        case .invalidOptions:
            "The observation options are invalid"
        case let .systemError(code):
            "The clamshell-angle device failed with IOKit error \(Self.hex(code))"
        }
    }

    private static func hex(_ code: Int32) -> String {
        String(format: "0x%08x", UInt32(bitPattern: code))
    }
}
