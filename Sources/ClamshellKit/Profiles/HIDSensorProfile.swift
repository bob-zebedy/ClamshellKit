enum HIDReportKind: Sendable {
    case feature
}

struct HIDReportRequest: Sendable {
    let kind: HIDReportKind
    let id: Int
    let maximumLength: Int
}

protocol HIDSensorProfile: Sendable {
    /// A broad match used to discover devices belonging to this sensor family.
    var candidateMatch: HIDDeviceMatch { get }

    /// The exact device layout understood by this profile.
    var deviceMatch: HIDDeviceMatch { get }

    var reportRequest: HIDReportRequest { get }
    var maximumObservationFrequency: Double { get }

    func decode(report: [UInt8], length: Int) throws -> ClamshellAngle
}
