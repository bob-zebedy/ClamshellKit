import Foundation
import IOKit.hid

struct HIDDeviceMatch: Sendable, Equatable {
    let vendorID: Int?
    let productID: Int?
    let primaryUsagePage: Int?
    let primaryUsage: Int?
    let transport: String?
    let isBuiltIn: Bool?

    init(
        vendorID: Int? = nil,
        productID: Int? = nil,
        primaryUsagePage: Int? = nil,
        primaryUsage: Int? = nil,
        transport: String? = nil,
        isBuiltIn: Bool? = nil
    ) {
        self.vendorID = vendorID
        self.productID = productID
        self.primaryUsagePage = primaryUsagePage
        self.primaryUsage = primaryUsage
        self.transport = transport
        self.isBuiltIn = isBuiltIn
    }

    var dictionary: [String: Any] {
        var result: [String: Any] = [:]

        if let vendorID {
            result[kIOHIDVendorIDKey as String] = vendorID
        }
        if let productID {
            result[kIOHIDProductIDKey as String] = productID
        }
        if let primaryUsagePage {
            result[kIOHIDPrimaryUsagePageKey as String] = primaryUsagePage
        }
        if let primaryUsage {
            result[kIOHIDPrimaryUsageKey as String] = primaryUsage
        }
        if let transport {
            result[kIOHIDTransportKey as String] = transport
        }
        if let isBuiltIn {
            result[kIOHIDBuiltInKey as String] = isBuiltIn
        }

        return result
    }

    func matches(_ device: HIDDeviceDescriptor) -> Bool {
        matches(device.vendorID, expected: vendorID)
            && matches(device.productID, expected: productID)
            && matches(device.primaryUsagePage, expected: primaryUsagePage)
            && matches(device.primaryUsage, expected: primaryUsage)
            && matches(device.transport, expected: transport)
            && matches(device.isBuiltIn, expected: isBuiltIn)
    }

    private func matches<Value: Equatable>(
        _ actual: Value?,
        expected: Value?
    ) -> Bool {
        guard let expected else {
            return true
        }

        return actual == expected
    }
}
