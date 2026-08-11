/// The first HID report layout understood by ClamshellKit
///
/// `V1` identifies this library's layout version, not an Apple protocol version
struct AppleHIDOrientationV1Profile: HIDSensorProfile {
    private static let sensorUsagePage = 0x0020
    private static let deviceOrientationUsage = 0x008A
    private static let angleUsage = 0x047F
    private static let angleReportID = 1

    let identifier = "apple-hid-orientation-v1"

    let candidateMatch = HIDDeviceMatch(
        primaryUsagePage: Self.sensorUsagePage,
        primaryUsage: Self.deviceOrientationUsage
    )

    let readStrategy = HIDReadStrategy.featureReport(
        id: Self.angleReportID,
        maximumLength: 8
    )

    let maximumObservationFrequency = 60.0

    private let knownDeviceMatches = [
        HIDDeviceMatch(
            vendorID: 0x05AC,
            productID: 0x8104,
            primaryUsagePage: Self.sensorUsagePage,
            primaryUsage: Self.deviceOrientationUsage
        )
    ]

    func evaluate(device: HIDDeviceDescriptor) -> HIDProfileEvaluation {
        guard candidateMatch.matches(device) else {
            return .rejected(.candidateMismatch)
        }

        guard device.isBuiltIn != false else {
            return .rejected(.externalDevice)
        }

        guard supportsLayout(of: device) else {
            return .rejected(.incompatibleLayout)
        }

        if knownDeviceMatches.contains(where: { $0.matches(device) }) {
            return .matched(.knownDevice)
        }

        // Unknown identities need positive evidence that this is an internal sensor
        guard device.isBuiltIn == true || device.transport == "SPU" else {
            return .rejected(.missingInternalEvidence)
        }

        return .matched(.compatibleLayout)
    }

    func decode(report: [UInt8], length: Int) throws -> HIDDecodeResult {
        guard length >= 3,
              report.count >= length,
              report[0] == UInt8(Self.angleReportID) else {
            throw ClamshellError.invalidData
        }

        let rawAngle =
            UInt16(report[1])
                | (UInt16(report[2]) << 8)

        guard rawAngle <= 360 else {
            throw ClamshellError.invalidData
        }

        let degrees = Double(rawAngle)
        return HIDDecodeResult(
            angle: ClamshellAngle(degrees: degrees),
            rawValue: degrees
        )
    }

    private func supportsLayout(of device: HIDDeviceDescriptor) -> Bool {
        device.elements.contains { element in
            element.reportKind == .input
                && element.usagePage == Self.sensorUsagePage
                && element.usage == Self.angleUsage
                && element.reportID == Self.angleReportID
                && element.reportSize == 9
                && element.reportCount == 1
                && element.logicalMinimum == 0
                && element.logicalMaximum == 360
                && !element.isRelative
                && !element.isArray
        }
    }
}
