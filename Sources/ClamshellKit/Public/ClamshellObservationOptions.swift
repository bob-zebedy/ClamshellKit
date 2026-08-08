/// Options that control delivery of observed angle changes.
public struct ClamshellObservationOptions: Sendable, Equatable {
    public static let `default` = Self()

    /// The maximum number of values delivered per second.
    ///
    /// A value of `nil` disables additional throttling. The underlying source
    /// may still impose a lower rate.
    public var maximumFrequency: Double?

    /// Creates observation options.
    ///
    /// - Parameter maximumFrequency: The maximum number of values delivered
    ///   per second. The default is 30 Hz.
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
