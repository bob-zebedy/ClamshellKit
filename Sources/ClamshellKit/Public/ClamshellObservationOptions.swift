/// Options that control delivery of observed clamshell readings
public struct ClamshellObservationOptions: Sendable, Equatable {
    public static let `default` = Self()

    /// The maximum number of values delivered per second
    ///
    /// A value of `nil` disables delivery throttling
    /// The underlying source still determines the internal sampling rate
    public var maximumFrequency: Double?

    /// Creates observation options
    ///
    /// - Parameter maximumFrequency: The maximum number of values delivered
    ///   per second with a default of 30 Hz
    public init(maximumFrequency: Double? = 30) {
        self.maximumFrequency = maximumFrequency
    }

    var isValid: Bool {
        guard let maximumFrequency else {
            return true
        }

        return maximumFrequency.isFinite && maximumFrequency > 0
    }
}
