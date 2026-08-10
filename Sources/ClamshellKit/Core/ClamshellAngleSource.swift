protocol ClamshellAngleSource: AnyObject, Sendable {
    /// The fastest rate at which this source should be polled
    var maximumObservationFrequency: Double { get }

    func open() throws
    func close()
    func read() throws -> ClamshellAngle
}
