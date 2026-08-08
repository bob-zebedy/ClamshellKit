import Foundation
import IOKit.hid

struct HIDDeviceMatch: Sendable, Equatable {
    let vendorID: Int?
    let productID: Int?
    let primaryUsagePage: Int?
    let primaryUsage: Int?

    init(
        vendorID: Int? = nil,
        productID: Int? = nil,
        primaryUsagePage: Int? = nil,
        primaryUsage: Int? = nil
    ) {
        self.vendorID = vendorID
        self.productID = productID
        self.primaryUsagePage = primaryUsagePage
        self.primaryUsage = primaryUsage
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

        return result
    }

    func matches(_ device: IOHIDDevice) -> Bool {
        matches(property: kIOHIDVendorIDKey, expected: vendorID, on: device)
            && matches(property: kIOHIDProductIDKey, expected: productID, on: device)
            && matches(
                property: kIOHIDPrimaryUsagePageKey,
                expected: primaryUsagePage,
                on: device
            )
            && matches(
                property: kIOHIDPrimaryUsageKey,
                expected: primaryUsage,
                on: device
            )
    }

    private func matches(
        property key: String,
        expected: Int?,
        on device: IOHIDDevice
    ) -> Bool {
        guard let expected else {
            return true
        }

        guard let number = IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber else {
            return false
        }

        return number.intValue == expected
    }
}
