/// A snapshot of the clamshell's angle and estimated rotational motion.
public struct ClamshellReading: Sendable, Equatable {
    /// The current angle between the display and the base.
    public let angle: ClamshellAngle

    /// The estimated angular velocity in degrees per second.
    ///
    /// Positive values indicate opening; negative values indicate closing.
    public let angularVelocity: Double

    /// The estimated angular acceleration in degrees per second squared.
    public let angularAcceleration: Double

    public init(
        angle: ClamshellAngle,
        angularVelocity: Double,
        angularAcceleration: Double
    ) {
        self.angle = angle
        self.angularVelocity = angularVelocity
        self.angularAcceleration = angularAcceleration
    }
}
