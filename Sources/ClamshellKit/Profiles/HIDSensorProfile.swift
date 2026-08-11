enum HIDReadStrategy: Sendable, Equatable {
    case featureReport(id: Int, maximumLength: Int)
}

enum HIDProfileMatch: Int, Sendable, Equatable, Comparable {
    /// The device is not in the known identity list, but its HID layout is compatible
    case compatibleLayout = 1

    /// Both the device identity and HID layout are known
    case knownDevice = 2

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum HIDProfileRejectionReason: String, Sendable, Equatable {
    case candidateMismatch
    case externalDevice
    case incompatibleLayout
    case missingInternalEvidence
}

enum HIDProfileEvaluation: Sendable, Equatable {
    case matched(HIDProfileMatch)
    case rejected(HIDProfileRejectionReason)
}

struct HIDDecodeResult: Sendable, Equatable {
    let angle: ClamshellAngle
    let rawValue: Double
}

protocol HIDSensorProfile: Sendable {
    /// A stable identifier used in diagnostics and registry maintenance
    var identifier: String { get }

    /// A broad match used to discover devices belonging to this sensor family
    var candidateMatch: HIDDeviceMatch { get }

    var readStrategy: HIDReadStrategy { get }
    var maximumObservationFrequency: Double { get }

    /// Explains whether and how confidently this profile understands the device
    ///
    /// A profile must validate the HID layout even when the device identity is known
    func evaluate(device: HIDDeviceDescriptor) -> HIDProfileEvaluation

    func decode(report: [UInt8], length: Int) throws -> HIDDecodeResult
}

struct HIDProfileEvaluationRecord: Sendable {
    let profile: any HIDSensorProfile
    let evaluation: HIDProfileEvaluation
}

struct HIDProfileSelection: Sendable {
    let profile: any HIDSensorProfile
    let match: HIDProfileMatch
}

struct HIDProfileSelectionAmbiguity: Sendable, Equatable {
    let match: HIDProfileMatch
    let candidateCount: Int
}

enum HIDProfileSelectionResult: Sendable {
    case selected(HIDProfileSelection)
    case unsupported
    case ambiguous(HIDProfileSelectionAmbiguity)

    var selection: HIDProfileSelection? {
        guard case let .selected(selection) = self else {
            return nil
        }

        return selection
    }

    var strongestMatch: HIDProfileMatch? {
        switch self {
        case let .selected(selection):
            selection.match
        case let .ambiguous(ambiguity):
            ambiguity.match
        case .unsupported:
            nil
        }
    }
}

enum HIDProfileSelector {
    static func evaluate(
        device: HIDDeviceDescriptor,
        profiles: [any HIDSensorProfile]
    ) -> [HIDProfileEvaluationRecord] {
        profiles.map { profile in
            HIDProfileEvaluationRecord(
                profile: profile,
                evaluation: profile.evaluate(device: device)
            )
        }
    }

    static func select(
        device: HIDDeviceDescriptor,
        profiles: [any HIDSensorProfile]
    ) -> HIDProfileSelectionResult {
        select(evaluations: evaluate(device: device, profiles: profiles))
    }

    static func select(
        evaluations: [HIDProfileEvaluationRecord]
    ) -> HIDProfileSelectionResult {
        let selections = evaluations.compactMap { record -> HIDProfileSelection? in
            guard case let .matched(match) = record.evaluation else {
                return nil
            }

            return HIDProfileSelection(profile: record.profile, match: match)
        }

        guard let strongestMatch = selections.map(\.match).max() else {
            return .unsupported
        }

        let strongestSelections = selections.filter {
            $0.match == strongestMatch
        }

        guard strongestSelections.count == 1,
              let selection = strongestSelections.first else {
            return .ambiguous(
                HIDProfileSelectionAmbiguity(
                    match: strongestMatch,
                    candidateCount: strongestSelections.count
                )
            )
        }

        return .selected(selection)
    }
}

enum HIDProfileRegistry {
    static var defaultProfiles: [any HIDSensorProfile] {
        [AppleHIDOrientationV1Profile()]
    }
}
