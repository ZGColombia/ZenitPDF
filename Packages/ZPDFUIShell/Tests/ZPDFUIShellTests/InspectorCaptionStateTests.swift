import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIShell

/// NL-MEASURE-09: the Inspector's Caption menu toggles fields around the headline.
@Suite("Inspector caption state (NL-MEASURE-09)", .shellTierSerialised)
struct InspectorCaptionStateTests {

    static func state(chosen: [MeasurementField]?) -> InspectorCaptionState {
        InspectorCaptionState(
            selection: [UUID()], availableFields: [.netArea, .perimeter, .planArea],
            chosenFields: chosen, headline: .netArea, offersSegmentLengths: true,
            showsSegmentLengths: false, hasLabelOffset: false
        )
    }

    @Test("Adding Perimeter to the headline shows both; removing it returns to the default (empty)")
    func toggling() {
        let plain = Self.state(chosen: [])
        #expect(plain.shownFields == [.netArea])
        #expect(plain.toggling(.perimeter) == [.netArea, .perimeter])
        let both = Self.state(chosen: [.netArea, .perimeter])
        #expect(both.toggling(.perimeter) == [], "back to the headline alone is stored as the default")
        // Removing the headline keeps the other field; removing the last one falls back.
        #expect(both.toggling(.netArea) == [.perimeter])
        #expect(Self.state(chosen: [.perimeter]).toggling(.perimeter) == [])
        #expect(Self.state(chosen: nil).shownFields.isEmpty, "a mixed selection shows no checkmarks")
    }
}
