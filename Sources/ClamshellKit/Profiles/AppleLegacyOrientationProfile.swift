struct AppleLegacyOrientationProfile: HIDSensorProfile {
    let candidateMatch = HIDDeviceMatch(
        vendorID: 0x05AC,
        primaryUsagePage: 0x0020,
        primaryUsage: 0x008A
    )

    let deviceMatch = HIDDeviceMatch(
        vendorID: 0x05AC,
        productID: 0x8104,
        primaryUsagePage: 0x0020,
        primaryUsage: 0x008A
    )

    let reportRequest = HIDReportRequest(
        kind: .feature,
        id: 1,
        maximumLength: 8
    )

    let maximumObservationFrequency = 60.0

    func decode(report: [UInt8], length: Int) throws -> ClamshellAngle {
        guard length >= 3, report.count >= length else {
            throw ClamshellError.invalidData
        }

        let rawAngle =
            UInt16(report[1])
                | (UInt16(report[2]) << 8)

        // This profile's HID descriptor declares a logical range of 0...360°.
        guard rawAngle <= 360 else {
            throw ClamshellError.invalidData
        }

        return ClamshellAngle(degrees: Double(rawAngle))
    }
}
