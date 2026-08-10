/// The current availability of clamshell-angle readings
public enum ClamshellStatus: Sendable, Equatable {
    /// A compatible device was found and produced a valid reading
    case available

    /// A compatible device may exist but cannot be used right now
    case unavailable

    /// No candidate angle device was found
    case notFound

    /// A candidate device was found but its report format is unsupported
    case unsupported

    /// macOS denied access to the device
    case accessDenied

    public var isAvailable: Bool {
        self == .available
    }
}
