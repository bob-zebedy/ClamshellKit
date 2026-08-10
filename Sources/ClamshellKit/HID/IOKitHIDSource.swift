import Foundation
import IOKit.hid

/// Confines IOKit references to the `ClamshellMonitorCore` actor
///
/// The unchecked conformance only permits ownership transfer into that actor
/// Callers must not invoke this type concurrently
final class IOKitHIDSource: ClamshellAngleSource, @unchecked Sendable {
    private let profiles: [any HIDSensorProfile]

    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var profile: (any HIDSensorProfile)?

    init(
        profiles: [any HIDSensorProfile] = [AppleLegacyOrientationProfile()]
    ) {
        self.profiles = profiles
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
            throw Self.map(managerResult, fallback: .unavailable)
        }

        guard
            let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
            !devices.isEmpty else {
            IOHIDManagerClose(manager, options)
            throw ClamshellError.notFound
        }

        guard let selection = selectDevice(from: devices) else {
            IOHIDManagerClose(manager, options)
            throw ClamshellError.unsupported
        }

        self.manager = manager
        device = selection.device
        profile = selection.profile
    }

    func close() {
        let options = IOOptionBits(kIOHIDOptionsTypeNone)

        if let manager {
            IOHIDManagerClose(manager, options)
        }

        profile = nil
        device = nil
        manager = nil
    }

    func read() throws -> ClamshellAngle {
        guard let device, let profile else {
            throw ClamshellError.disconnected
        }

        let request = profile.reportRequest
        var report = [UInt8](repeating: 0, count: request.maximumLength)
        var length = CFIndex(report.count)

        let result = report.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.bindMemory(to: UInt8.self).baseAddress else {
                return kIOReturnNoMemory
            }

            return IOHIDDeviceGetReport(
                device,
                request.kind.ioKitValue,
                CFIndex(request.id),
                baseAddress,
                &length
            )
        }

        guard result == kIOReturnSuccess else {
            throw Self.map(result, fallback: .unavailable)
        }

        return try profile.decode(report: report, length: Int(length))
    }

    deinit {
        close()
    }

    private func selectDevice(
        from devices: Set<IOHIDDevice>
    ) -> (device: IOHIDDevice, profile: any HIDSensorProfile)? {
        for profile in profiles {
            if let device = devices.first(where: profile.deviceMatch.matches) {
                return (device, profile)
            }
        }

        return nil
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
}

private extension HIDReportKind {
    var ioKitValue: IOHIDReportType {
        switch self {
        case .feature:
            kIOHIDReportTypeFeature
        }
    }
}
