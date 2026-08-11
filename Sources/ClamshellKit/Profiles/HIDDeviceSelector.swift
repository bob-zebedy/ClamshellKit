struct HIDDeviceProfileAssessment: Sendable {
    let deviceIndex: Int
    let profileSelection: HIDProfileSelectionResult
}

struct HIDDeviceSelection: Sendable {
    let deviceIndex: Int
    let profile: any HIDSensorProfile
    let match: HIDProfileMatch
}

struct HIDDeviceSelectionAmbiguity: Sendable, Equatable {
    enum Scope: String, Sendable, Equatable {
        case profile
        case device
    }

    let scope: Scope
    let match: HIDProfileMatch
    let candidateCount: Int
}

enum HIDDeviceSelectionResult: Sendable {
    case selected(HIDDeviceSelection)
    case unsupported
    case ambiguous(HIDDeviceSelectionAmbiguity)
}

enum HIDDeviceSelector {
    static func select(
        from assessments: [HIDDeviceProfileAssessment]
    ) -> HIDDeviceSelectionResult {
        let matchedAssessments = assessments.compactMap { assessment in
            assessment.profileSelection.strongestMatch.map { match in
                (assessment: assessment, match: match)
            }
        }

        guard let strongestMatch = matchedAssessments.map(\.match).max() else {
            return .unsupported
        }

        let strongestAssessments = matchedAssessments.filter {
            $0.match == strongestMatch
        }

        guard strongestAssessments.count == 1,
              let assessment = strongestAssessments.first?.assessment else {
            return .ambiguous(
                HIDDeviceSelectionAmbiguity(
                    scope: .device,
                    match: strongestMatch,
                    candidateCount: strongestAssessments.count
                )
            )
        }

        switch assessment.profileSelection {
        case let .selected(selection):
            return .selected(
                HIDDeviceSelection(
                    deviceIndex: assessment.deviceIndex,
                    profile: selection.profile,
                    match: selection.match
                )
            )
        case let .ambiguous(ambiguity):
            return .ambiguous(
                HIDDeviceSelectionAmbiguity(
                    scope: .profile,
                    match: ambiguity.match,
                    candidateCount: ambiguity.candidateCount
                )
            )
        case .unsupported:
            return .unsupported
        }
    }
}
