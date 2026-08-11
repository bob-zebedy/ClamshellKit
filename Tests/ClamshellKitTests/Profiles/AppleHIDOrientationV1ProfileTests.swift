@testable import ClamshellKit
import XCTest

final class AppleHIDOrientationV1ProfileTests: XCTestCase {
    private let profile = AppleHIDOrientationV1Profile()

    func testUsesVersionOneFeatureReportStrategy() {
        XCTAssertEqual(profile.identifier, "apple-hid-orientation-v1")
        XCTAssertEqual(
            profile.readStrategy,
            .featureReport(id: 1, maximumLength: 8)
        )
        XCTAssertEqual(profile.maximumObservationFrequency, 60)
    }

    func testDefaultRegistryContainsVersionOneProfile() {
        XCTAssertEqual(
            HIDProfileRegistry.defaultProfiles.map(\.identifier),
            ["apple-hid-orientation-v1"]
        )
    }

    func testKnownDeviceRequiresCompatibleLayout() {
        XCTAssertEqual(
            profile.evaluate(device: makeDevice()),
            .matched(.knownDevice)
        )
    }

    func testCompatibleLayoutAcceptsUnknownProductID() {
        XCTAssertEqual(
            profile.evaluate(device: makeDevice(productID: 0xFFFF)),
            .matched(.compatibleLayout)
        )
    }

    func testCompatibleLayoutAcceptsUnknownVendorID() {
        XCTAssertEqual(
            profile.evaluate(device: makeDevice(vendorID: 0xFFFF)),
            .matched(.compatibleLayout)
        )
    }

    func testCompatibleLayoutUsesSPUAsInternalEvidence() {
        XCTAssertEqual(
            profile.evaluate(
                device: makeDevice(
                    vendorID: 0xFFFF,
                    productID: 0xFFFF,
                    isBuiltIn: nil
                )
            ),
            .matched(.compatibleLayout)
        )
    }

    func testCandidateFamilyMismatchIsRejected() {
        let device = HIDDeviceDescriptor(
            vendorID: 0x05AC,
            productID: 0x8104,
            primaryUsagePage: 0x0001,
            primaryUsage: 0x0001,
            transport: "SPU",
            isBuiltIn: true,
            elements: [makeAngleElement()]
        )

        XCTAssertEqual(
            profile.evaluate(device: device),
            .rejected(.candidateMismatch)
        )
    }

    func testUnknownExternalDeviceIsRejected() {
        XCTAssertEqual(
            profile.evaluate(
                device: makeDevice(
                    vendorID: 0xFFFF,
                    productID: 0xFFFF,
                    transport: "USB",
                    isBuiltIn: false
                )
            ),
            .rejected(.externalDevice)
        )
    }

    func testUnknownDeviceWithoutInternalEvidenceIsRejected() {
        let device = makeDevice(
            vendorID: 0xFFFF,
            productID: 0xFFFF,
            transport: nil,
            isBuiltIn: nil
        )

        XCTAssertEqual(
            profile.evaluate(device: device),
            .rejected(.missingInternalEvidence)
        )
    }

    func testKnownIdentityWithChangedLayoutIsRejected() {
        XCTAssertEqual(
            profile.evaluate(
                device: makeDevice(
                    elements: [makeAngleElement(reportSize: 16)]
                )
            ),
            .rejected(.incompatibleLayout)
        )
    }

    func testDecodesLittleEndianAngle() throws {
        let result = try profile.decode(
            report: [1, 0x0E, 0x01, 0, 0, 0, 0, 0],
            length: 8
        )

        XCTAssertEqual(result.angle, ClamshellAngle(degrees: 270))
        XCTAssertEqual(result.rawValue, 270)
    }

    func testRejectsUnexpectedReportID() {
        XCTAssertThrowsError(
            try profile.decode(report: [2, 90, 0], length: 3)
        ) { error in
            XCTAssertEqual(error as? ClamshellError, .invalidData)
        }
    }

    func testRejectsShortReport() {
        XCTAssertThrowsError(
            try profile.decode(report: [1, 90], length: 2)
        ) { error in
            XCTAssertEqual(error as? ClamshellError, .invalidData)
        }
    }

    func testRejectsAngleOutsideLogicalRange() {
        XCTAssertThrowsError(
            try profile.decode(report: [1, 0x69, 0x01], length: 3)
        ) { error in
            XCTAssertEqual(error as? ClamshellError, .invalidData)
        }
    }

    private func makeDevice(
        vendorID: Int? = 0x05AC,
        productID: Int? = 0x8104,
        transport: String? = "SPU",
        isBuiltIn: Bool? = true,
        elements: [HIDElementDescriptor]? = nil
    ) -> HIDDeviceDescriptor {
        HIDDeviceDescriptor(
            vendorID: vendorID,
            productID: productID,
            primaryUsagePage: 0x0020,
            primaryUsage: 0x008A,
            transport: transport,
            isBuiltIn: isBuiltIn,
            elements: elements ?? [makeAngleElement()]
        )
    }

    private func makeAngleElement(
        reportSize: Int = 9
    ) -> HIDElementDescriptor {
        HIDElementDescriptor(
            reportKind: .input,
            usagePage: 0x0020,
            usage: 0x047F,
            reportID: 1,
            reportSize: reportSize,
            reportCount: 1,
            logicalMinimum: 0,
            logicalMaximum: 360,
            physicalMinimum: 0,
            physicalMaximum: 360
        )
    }
}
