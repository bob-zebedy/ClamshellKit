import Foundation
import IOKit.hid

enum HIDElementReportKind: Sendable, Equatable {
    case input
    case output
    case feature
    case collection
    case unknown
}

struct HIDElementDescriptor: Sendable, Equatable {
    let reportKind: HIDElementReportKind
    let usagePage: Int
    let usage: Int
    let reportID: Int
    let reportSize: Int
    let reportCount: Int
    let logicalMinimum: Int
    let logicalMaximum: Int
    let physicalMinimum: Int
    let physicalMaximum: Int
    let unit: Int
    let unitExponent: Int
    let isRelative: Bool
    let isArray: Bool

    init(
        reportKind: HIDElementReportKind,
        usagePage: Int,
        usage: Int,
        reportID: Int,
        reportSize: Int,
        reportCount: Int,
        logicalMinimum: Int,
        logicalMaximum: Int,
        physicalMinimum: Int = 0,
        physicalMaximum: Int = 0,
        unit: Int = 0,
        unitExponent: Int = 0,
        isRelative: Bool = false,
        isArray: Bool = false
    ) {
        self.reportKind = reportKind
        self.usagePage = usagePage
        self.usage = usage
        self.reportID = reportID
        self.reportSize = reportSize
        self.reportCount = reportCount
        self.logicalMinimum = logicalMinimum
        self.logicalMaximum = logicalMaximum
        self.physicalMinimum = physicalMinimum
        self.physicalMaximum = physicalMaximum
        self.unit = unit
        self.unitExponent = unitExponent
        self.isRelative = isRelative
        self.isArray = isArray
    }

    init(element: IOHIDElement) {
        reportKind = Self.reportKind(for: IOHIDElementGetType(element))
        usagePage = Int(IOHIDElementGetUsagePage(element))
        usage = Int(IOHIDElementGetUsage(element))
        reportID = Int(IOHIDElementGetReportID(element))
        reportSize = Int(IOHIDElementGetReportSize(element))
        reportCount = Int(IOHIDElementGetReportCount(element))
        logicalMinimum = IOHIDElementGetLogicalMin(element)
        logicalMaximum = IOHIDElementGetLogicalMax(element)
        physicalMinimum = IOHIDElementGetPhysicalMin(element)
        physicalMaximum = IOHIDElementGetPhysicalMax(element)
        unit = Int(IOHIDElementGetUnit(element))
        unitExponent = Int(IOHIDElementGetUnitExponent(element))
        isRelative = IOHIDElementIsRelative(element)
        isArray = IOHIDElementIsArray(element)
    }

    private static func reportKind(
        for type: IOHIDElementType
    ) -> HIDElementReportKind {
        switch type {
        case kIOHIDElementTypeInput_Misc,
             kIOHIDElementTypeInput_Button,
             kIOHIDElementTypeInput_Axis,
             kIOHIDElementTypeInput_ScanCodes,
             kIOHIDElementTypeInput_NULL:
            .input
        case kIOHIDElementTypeOutput:
            .output
        case kIOHIDElementTypeFeature:
            .feature
        case kIOHIDElementTypeCollection:
            .collection
        default:
            .unknown
        }
    }
}

struct HIDDeviceDescriptor: Sendable, Equatable {
    let vendorID: Int?
    let productID: Int?
    let primaryUsagePage: Int?
    let primaryUsage: Int?
    let transport: String?
    let isBuiltIn: Bool?
    let elements: [HIDElementDescriptor]

    init(
        vendorID: Int? = nil,
        productID: Int? = nil,
        primaryUsagePage: Int? = nil,
        primaryUsage: Int? = nil,
        transport: String? = nil,
        isBuiltIn: Bool? = nil,
        elements: [HIDElementDescriptor] = []
    ) {
        self.vendorID = vendorID
        self.productID = productID
        self.primaryUsagePage = primaryUsagePage
        self.primaryUsage = primaryUsage
        self.transport = transport
        self.isBuiltIn = isBuiltIn
        self.elements = elements
    }

    init(device: IOHIDDevice) {
        vendorID = Self.integerProperty(kIOHIDVendorIDKey, on: device)
        productID = Self.integerProperty(kIOHIDProductIDKey, on: device)
        primaryUsagePage = Self.integerProperty(kIOHIDPrimaryUsagePageKey, on: device)
        primaryUsage = Self.integerProperty(kIOHIDPrimaryUsageKey, on: device)
        transport = Self.stringProperty(kIOHIDTransportKey, on: device)
        isBuiltIn = Self.booleanProperty(kIOHIDBuiltInKey, on: device)

        let options = IOOptionBits(kIOHIDOptionsTypeNone)
        let ioKitElements = IOHIDDeviceCopyMatchingElements(
            device,
            nil,
            options
        ) as? [IOHIDElement]
        elements = ioKitElements?.map(HIDElementDescriptor.init) ?? []
    }

    private static func integerProperty(
        _ key: String,
        on device: IOHIDDevice
    ) -> Int? {
        let value = IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber
        return value?.intValue
    }

    private static func stringProperty(
        _ key: String,
        on device: IOHIDDevice
    ) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }

    private static func booleanProperty(
        _ key: String,
        on device: IOHIDDevice
    ) -> Bool? {
        let value = IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber
        return value?.boolValue
    }
}
