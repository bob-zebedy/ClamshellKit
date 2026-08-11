import Foundation
import IOKit.hid

/// Confines IOKit references to the `ClamshellMonitorCore` actor
///
/// The unchecked conformance only permits ownership transfer into that actor
/// Callers must not invoke this type concurrently
final class IOKitHIDSource: ClamshellAngleSource, @unchecked Sendable {
    private let profiles: [any HIDSensorProfile]
    private let diagnostics: ClamshellDiagnosticHub

    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var profile: (any HIDSensorProfile)?

    init(
        profiles: [any HIDSensorProfile] = HIDProfileRegistry.defaultProfiles,
        diagnostics: ClamshellDiagnosticHub = ClamshellDiagnosticHub()
    ) {
        self.profiles = profiles
        self.diagnostics = diagnostics
    }

    var maximumObservationFrequency: Double {
        profile?.maximumObservationFrequency
            ?? profiles.map(\.maximumObservationFrequency).max()
            ?? 20
    }

    func open() throws {
        guard device == nil else {
            return
        }

        diagnostics.emit(
            .sourceOpening,
            level: .basic,
            fields: ["profileCount": .integer(Int64(profiles.count))]
        )

        let options = IOOptionBits(kIOHIDOptionsTypeNone)
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, options)

        let candidateMatches = profiles.map(\.candidateMatch.dictionary)
        if candidateMatches.count == 1, let match = candidateMatches.first {
            IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        } else {
            IOHIDManagerSetDeviceMatchingMultiple(
                manager,
                candidateMatches as CFArray
            )
        }

        // Install matching before opening because a manager opens all matching devices
        //
        // Opening the selected device again would create an unnecessary second open/close lifecycle
        let managerResult = IOHIDManagerOpen(manager, options)
        guard managerResult == kIOReturnSuccess else {
            let error = Self.map(managerResult, fallback: .unavailable)
            emitFailure(
                operation: "manager.open",
                result: managerResult,
                error: error
            )
            throw error
        }

        guard
            let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
            !devices.isEmpty else {
            IOHIDManagerClose(manager, options)
            diagnostics.emit(
                .deviceDiscovery,
                level: .basic,
                fields: ["candidateCount": .integer(0)]
            )
            emitFailure(operation: "device.discovery", error: .notFound)
            throw ClamshellError.notFound
        }

        diagnostics.emit(
            .deviceDiscovery,
            level: .basic,
            fields: ["candidateCount": .integer(Int64(devices.count))]
        )

        let candidateDevices = Array(devices)
        let selection: HIDDeviceSelection

        do {
            selection = try selectedDevice(from: candidateDevices)
        } catch {
            IOHIDManagerClose(manager, options)
            throw error
        }

        self.manager = manager
        device = candidateDevices[selection.deviceIndex]
        profile = selection.profile
        diagnostics.emit(
            .profileSelected,
            level: .basic,
            fields: [
                "deviceIndex": .integer(Int64(selection.deviceIndex)),
                "match": .string(selection.match.diagnosticName),
                "profile": .string(selection.profile.identifier)
            ]
        )
        diagnostics.emit(
            .sourceOpened,
            level: .basic,
            fields: ["profile": .string(selection.profile.identifier)]
        )
    }

    func close() {
        let options = IOOptionBits(kIOHIDOptionsTypeNone)

        let wasOpen = manager != nil

        if let manager {
            IOHIDManagerClose(manager, options)
        }

        profile = nil
        device = nil
        manager = nil

        if wasOpen {
            diagnostics.emit(.sourceClosed, level: .basic, fields: [:])
        }
    }

    func read() throws -> ClamshellAngle {
        guard let device, let profile else {
            throw ClamshellError.disconnected
        }

        let response = try read(
            strategy: profile.readStrategy,
            from: device
        )

        do {
            let decoded = try profile.decode(
                report: response.report,
                length: response.length
            )
            diagnostics.emit(
                .angleDecoded,
                level: .verbose,
                fields: [
                    "degrees": .floatingPoint(decoded.angle.degrees),
                    "profile": .string(profile.identifier),
                    "rawValue": .floatingPoint(decoded.rawValue)
                ]
            )
            return decoded.angle
        } catch {
            let normalized = Self.normalize(error)
            emitFailure(operation: "report.decode", error: normalized)
            throw normalized
        }
    }

    deinit {
        close()
    }

    private func read(
        strategy: HIDReadStrategy,
        from device: IOHIDDevice
    ) throws -> (report: [UInt8], length: Int) {
        switch strategy {
        case let .featureReport(id, maximumLength):
            try getReport(
                from: device,
                type: kIOHIDReportTypeFeature,
                id: id,
                maximumLength: maximumLength
            )
        }
    }

    private func getReport(
        from device: IOHIDDevice,
        type: IOHIDReportType,
        id: Int,
        maximumLength: Int
    ) throws -> (report: [UInt8], length: Int) {
        guard maximumLength > 0 else {
            emitFailure(operation: "report.configuration", error: .invalidData)
            throw ClamshellError.invalidData
        }

        var report = [UInt8](repeating: 0, count: maximumLength)
        var length = CFIndex(report.count)

        let result = report.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.bindMemory(to: UInt8.self).baseAddress else {
                return kIOReturnNoMemory
            }

            return IOHIDDeviceGetReport(
                device,
                type,
                CFIndex(id),
                baseAddress,
                &length
            )
        }

        guard result == kIOReturnSuccess else {
            let error = Self.map(result, fallback: .unavailable)
            emitFailure(
                operation: "report.get",
                result: result,
                error: error
            )
            throw error
        }

        diagnostics.emit(
            .reportRead,
            level: .verbose,
            fields: [
                "actualLength": .integer(Int64(length)),
                "maximumLength": .integer(Int64(maximumLength)),
                "reportID": .integer(Int64(id)),
                "reportType": .string(Self.name(for: type))
            ]
        )
        let validLength = max(0, min(Int(length), report.count))
        diagnostics.emit(
            .rawReport,
            level: .trace,
            fields: [
                "bytes": .bytes(Array(report.prefix(validLength))),
                "length": .integer(Int64(validLength)),
                "reportID": .integer(Int64(id)),
                "reportType": .string(Self.name(for: type))
            ]
        )

        return (report, Int(length))
    }

    private func selectDevice(
        from devices: [IOHIDDevice]
    ) -> HIDDeviceSelectionResult {
        var assessments: [HIDDeviceProfileAssessment] = []

        for (deviceIndex, device) in devices.enumerated() {
            let descriptor = HIDDeviceDescriptor(device: device)
            diagnostics.emit(
                .deviceCandidate,
                level: .verbose,
                fields: Self.fields(
                    for: descriptor,
                    deviceIndex: deviceIndex
                )
            )

            for (elementIndex, element) in descriptor.elements.enumerated() {
                diagnostics.emit(
                    .hidElement,
                    level: .verbose,
                    fields: Self.fields(
                        for: element,
                        deviceIndex: deviceIndex,
                        elementIndex: elementIndex
                    )
                )
            }

            let evaluations = HIDProfileSelector.evaluate(
                device: descriptor,
                profiles: profiles
            )

            for record in evaluations {
                diagnostics.emit(
                    .profileEvaluated,
                    level: .verbose,
                    fields: Self.fields(
                        for: record.evaluation,
                        profileIdentifier: record.profile.identifier,
                        deviceIndex: deviceIndex
                    )
                )
            }

            assessments.append(
                HIDDeviceProfileAssessment(
                    deviceIndex: deviceIndex,
                    profileSelection: HIDProfileSelector.select(
                        evaluations: evaluations
                    )
                )
            )
        }

        return HIDDeviceSelector.select(from: assessments)
    }

    private func selectedDevice(
        from devices: [IOHIDDevice]
    ) throws -> HIDDeviceSelection {
        switch selectDevice(from: devices) {
        case let .selected(selection):
            return selection
        case .unsupported:
            emitFailure(
                operation: "profile.selection",
                error: .unsupported,
                reason: "unsupported"
            )
        case let .ambiguous(ambiguity):
            emitFailure(
                operation: "profile.selection",
                error: .unsupported,
                reason: "ambiguous",
                ambiguity: ambiguity
            )
        }

        throw ClamshellError.unsupported
    }

    private static func map(
        _ result: IOReturn,
        fallback: ClamshellError
    ) -> ClamshellError {
        switch result {
        case kIOReturnNotPermitted, kIOReturnNotPrivileged:
            .accessDenied
        case kIOReturnBusy, kIOReturnExclusiveAccess, kIOReturnTimeout:
            .unavailable
        case kIOReturnNoDevice,
             kIOReturnNotOpen,
             kIOReturnOffline,
             kIOReturnNotAttached:
            .disconnected
        case kIOReturnUnsupported:
            .unsupported
        default:
            result == kIOReturnSuccess
                ? fallback
                : .systemError(code: result)
        }
    }

    private static func normalize(_ error: any Error) -> ClamshellError {
        if let error = error as? ClamshellError {
            return error
        }

        let nsError = error as NSError
        return .systemError(code: Int32(clamping: nsError.code))
    }

    private func emitFailure(
        operation: String,
        result: IOReturn? = nil,
        error: ClamshellError,
        reason: String? = nil,
        ambiguity: HIDDeviceSelectionAmbiguity? = nil
    ) {
        var fields: [String: ClamshellDiagnosticValue] = [
            "error": .string(error.diagnosticName),
            "operation": .string(operation)
        ]

        if let result {
            fields["ioReturn"] = .integer(Int64(result))
        }
        if let reason {
            fields["reason"] = .string(reason)
        }
        if let ambiguity {
            fields["ambiguityScope"] = .string(ambiguity.scope.rawValue)
            fields["candidateCount"] = .integer(Int64(ambiguity.candidateCount))
            fields["match"] = .string(ambiguity.match.diagnosticName)
        }

        diagnostics.emit(.failure, level: .basic, fields: fields)
    }
}

private extension IOKitHIDSource {
    static func name(for reportType: IOHIDReportType) -> String {
        switch reportType {
        case kIOHIDReportTypeInput:
            "input"
        case kIOHIDReportTypeOutput:
            "output"
        case kIOHIDReportTypeFeature:
            "feature"
        default:
            "unknown"
        }
    }

    static func fields(
        for descriptor: HIDDeviceDescriptor,
        deviceIndex: Int
    ) -> [String: ClamshellDiagnosticValue] {
        var fields: [String: ClamshellDiagnosticValue] = [
            "deviceIndex": .integer(Int64(deviceIndex)),
            "elementCount": .integer(Int64(descriptor.elements.count))
        ]

        if let vendorID = descriptor.vendorID {
            fields["vendorID"] = .integer(Int64(vendorID))
        }
        if let productID = descriptor.productID {
            fields["productID"] = .integer(Int64(productID))
        }
        if let primaryUsagePage = descriptor.primaryUsagePage {
            fields["primaryUsagePage"] = .integer(Int64(primaryUsagePage))
        }
        if let primaryUsage = descriptor.primaryUsage {
            fields["primaryUsage"] = .integer(Int64(primaryUsage))
        }
        if let transport = descriptor.transport {
            fields["transport"] = .string(transport)
        }
        if let isBuiltIn = descriptor.isBuiltIn {
            fields["isBuiltIn"] = .boolean(isBuiltIn)
        }

        return fields
    }

    static func fields(
        for element: HIDElementDescriptor,
        deviceIndex: Int,
        elementIndex: Int
    ) -> [String: ClamshellDiagnosticValue] {
        [
            "deviceIndex": .integer(Int64(deviceIndex)),
            "elementIndex": .integer(Int64(elementIndex)),
            "isArray": .boolean(element.isArray),
            "isRelative": .boolean(element.isRelative),
            "logicalMaximum": .integer(Int64(element.logicalMaximum)),
            "logicalMinimum": .integer(Int64(element.logicalMinimum)),
            "physicalMaximum": .integer(Int64(element.physicalMaximum)),
            "physicalMinimum": .integer(Int64(element.physicalMinimum)),
            "reportCount": .integer(Int64(element.reportCount)),
            "reportID": .integer(Int64(element.reportID)),
            "reportKind": .string(element.reportKind.diagnosticName),
            "reportSize": .integer(Int64(element.reportSize)),
            "unit": .integer(Int64(element.unit)),
            "unitExponent": .integer(Int64(element.unitExponent)),
            "usage": .integer(Int64(element.usage)),
            "usagePage": .integer(Int64(element.usagePage))
        ]
    }

    static func fields(
        for evaluation: HIDProfileEvaluation,
        profileIdentifier: String,
        deviceIndex: Int
    ) -> [String: ClamshellDiagnosticValue] {
        var fields: [String: ClamshellDiagnosticValue] = [
            "deviceIndex": .integer(Int64(deviceIndex)),
            "profile": .string(profileIdentifier)
        ]

        switch evaluation {
        case let .matched(match):
            fields["outcome"] = .string("matched")
            fields["match"] = .string(match.diagnosticName)
        case let .rejected(reason):
            fields["outcome"] = .string("rejected")
            fields["reason"] = .string(reason.rawValue)
        }

        return fields
    }
}

private extension HIDProfileMatch {
    var diagnosticName: String {
        switch self {
        case .compatibleLayout:
            "compatibleLayout"
        case .knownDevice:
            "knownDevice"
        }
    }
}

private extension HIDElementReportKind {
    var diagnosticName: String {
        switch self {
        case .input:
            "input"
        case .output:
            "output"
        case .feature:
            "feature"
        case .collection:
            "collection"
        case .unknown:
            "unknown"
        }
    }
}
