@testable import ClamshellKit
import XCTest

final class HIDProfileSelectorTests: XCTestCase {
    private let device = HIDDeviceDescriptor()

    func testUniqueStrongestProfileIsSelected() throws {
        let result = select(
            StubProfile(identifier: "layout-1", match: .compatibleLayout),
            StubProfile(identifier: "known", match: .knownDevice),
            StubProfile(identifier: "layout-2", match: .compatibleLayout)
        )

        let selection = try XCTUnwrap(result.selection)
        XCTAssertEqual(selection.profile.identifier, "known")
        XCTAssertEqual(selection.match, .knownDevice)
    }

    func testEqualStrongestProfilesAreAmbiguous() {
        let result = select(
            StubProfile(identifier: "first", match: .knownDevice),
            StubProfile(identifier: "second", match: .knownDevice),
            StubProfile(identifier: "layout", match: .compatibleLayout)
        )

        guard case let .ambiguous(ambiguity) = result else {
            return XCTFail("Expected an ambiguous profile selection")
        }

        XCTAssertEqual(ambiguity.match, .knownDevice)
        XCTAssertEqual(ambiguity.candidateCount, 2)
    }

    func testWeakerProfileOverlapDoesNotCauseAmbiguity() throws {
        let result = select(
            StubProfile(identifier: "layout-1", match: .compatibleLayout),
            StubProfile(identifier: "layout-2", match: .compatibleLayout),
            StubProfile(identifier: "known", match: .knownDevice)
        )

        let selection = try XCTUnwrap(result.selection)
        XCTAssertEqual(selection.profile.identifier, "known")
    }

    func testNoMatchingProfileIsUnsupported() {
        let result = select(
            StubProfile(identifier: "first", match: nil),
            StubProfile(identifier: "second", match: nil)
        )

        guard case .unsupported = result else {
            return XCTFail("Expected an unsupported profile selection")
        }
    }

    func testEvaluatePreservesRegistryOrder() {
        let evaluations = HIDProfileSelector.evaluate(
            device: device,
            profiles: [
                StubProfile(identifier: "first", match: .compatibleLayout),
                StubProfile(identifier: "second", match: nil)
            ]
        )

        XCTAssertEqual(evaluations.map(\.profile.identifier), ["first", "second"])
        XCTAssertEqual(
            evaluations.map(\.evaluation),
            [.matched(.compatibleLayout), .rejected(.incompatibleLayout)]
        )
    }

    private func select(
        _ profiles: StubProfile...
    ) -> HIDProfileSelectionResult {
        HIDProfileSelector.select(device: device, profiles: profiles)
    }
}

final class HIDDeviceSelectorTests: XCTestCase {
    func testUniqueStrongestDeviceIsSelected() {
        let result = HIDDeviceSelector.select(
            from: [
                assessment(index: 0, identifier: "layout", match: .compatibleLayout),
                assessment(index: 1, identifier: "known", match: .knownDevice)
            ]
        )

        guard case let .selected(selection) = result else {
            return XCTFail("Expected a selected device")
        }

        XCTAssertEqual(selection.deviceIndex, 1)
        XCTAssertEqual(selection.profile.identifier, "known")
        XCTAssertEqual(selection.match, .knownDevice)
    }

    func testEqualStrongestDevicesAreAmbiguous() {
        let result = HIDDeviceSelector.select(
            from: [
                assessment(index: 0, identifier: "first", match: .knownDevice),
                assessment(index: 1, identifier: "second", match: .knownDevice)
            ]
        )

        assertAmbiguity(
            result,
            scope: .device,
            match: .knownDevice,
            candidateCount: 2
        )
    }

    func testAmbiguousProfilesOnStrongestDeviceAreRejected() {
        let result = HIDDeviceSelector.select(
            from: [
                HIDDeviceProfileAssessment(
                    deviceIndex: 0,
                    profileSelection: .ambiguous(
                        HIDProfileSelectionAmbiguity(
                            match: .knownDevice,
                            candidateCount: 2
                        )
                    )
                ),
                assessment(index: 1, identifier: "layout", match: .compatibleLayout)
            ]
        )

        assertAmbiguity(
            result,
            scope: .profile,
            match: .knownDevice,
            candidateCount: 2
        )
    }

    func testUniqueStrongerDeviceWinsOverWeakerProfileAmbiguity() {
        let result = HIDDeviceSelector.select(
            from: [
                HIDDeviceProfileAssessment(
                    deviceIndex: 0,
                    profileSelection: .ambiguous(
                        HIDProfileSelectionAmbiguity(
                            match: .compatibleLayout,
                            candidateCount: 2
                        )
                    )
                ),
                assessment(index: 1, identifier: "known", match: .knownDevice)
            ]
        )

        guard case let .selected(selection) = result else {
            return XCTFail("Expected a selected device")
        }

        XCTAssertEqual(selection.deviceIndex, 1)
        XCTAssertEqual(selection.profile.identifier, "known")
    }

    func testNoSupportedDeviceIsUnsupported() {
        let result = HIDDeviceSelector.select(
            from: [
                HIDDeviceProfileAssessment(
                    deviceIndex: 0,
                    profileSelection: .unsupported
                )
            ]
        )

        guard case .unsupported = result else {
            return XCTFail("Expected an unsupported device selection")
        }
    }

    private func assessment(
        index: Int,
        identifier: String,
        match: HIDProfileMatch
    ) -> HIDDeviceProfileAssessment {
        HIDDeviceProfileAssessment(
            deviceIndex: index,
            profileSelection: .selected(
                HIDProfileSelection(
                    profile: StubProfile(identifier: identifier, match: match),
                    match: match
                )
            )
        )
    }

    private func assertAmbiguity(
        _ result: HIDDeviceSelectionResult,
        scope: HIDDeviceSelectionAmbiguity.Scope,
        match: HIDProfileMatch,
        candidateCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .ambiguous(ambiguity) = result else {
            return XCTFail(
                "Expected an ambiguous device selection",
                file: file,
                line: line
            )
        }

        XCTAssertEqual(ambiguity.scope, scope, file: file, line: line)
        XCTAssertEqual(ambiguity.match, match, file: file, line: line)
        XCTAssertEqual(
            ambiguity.candidateCount,
            candidateCount,
            file: file,
            line: line
        )
    }
}

private struct StubProfile: HIDSensorProfile {
    let identifier: String
    let match: HIDProfileMatch?
    let candidateMatch = HIDDeviceMatch()
    let readStrategy = HIDReadStrategy.featureReport(id: 0, maximumLength: 1)
    let maximumObservationFrequency = 1.0

    func evaluate(device _: HIDDeviceDescriptor) -> HIDProfileEvaluation {
        match.map(HIDProfileEvaluation.matched)
            ?? .rejected(.incompatibleLayout)
    }

    func decode(report _: [UInt8], length _: Int) throws -> HIDDecodeResult {
        HIDDecodeResult(angle: ClamshellAngle(degrees: 0), rawValue: 0)
    }
}
