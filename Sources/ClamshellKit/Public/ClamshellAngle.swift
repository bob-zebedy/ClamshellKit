/// The interior angle between a Mac notebook's display and its base.
public struct ClamshellAngle: Sendable, Equatable {
    /// The angle in degrees.
    public let degrees: Double

    public init(degrees: Double) {
        self.degrees = degrees
    }
}
