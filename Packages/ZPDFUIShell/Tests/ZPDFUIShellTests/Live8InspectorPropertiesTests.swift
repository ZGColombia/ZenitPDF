import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIShell

/// L-99 (live test 8): the Properties tab showed "How This Number Was Calculated" for a Note,
/// which has no number. Nothing here draws: the section list is a pure function of the selection.
@MainActor
@Suite("Live 8 — Properties sections for a selection without a number (L-99)", .shellTierSerialised)
struct Live8InspectorPropertiesTests {

    private static func summary(kind: MarkupKind, measurementKind: MeasurementKind? = nil) -> MarkupSummary {
        MarkupSummary(
            id: UUID(),
            kind: kind,
            measurementKind: measurementKind,
            subject: kind == .note ? "Notes" : "Floor",
            label: "",
            pageLabel: "A-101",
            pageID: PageDescriptor.ID(),
            pageIndex: 0,
            status: .none,
            author: "A. Berg",
            colorRGBA: ColorRGBA(red: 0.2, green: 0.4, blue: 1, alpha: 1),
            measurementFields: [],
            created: Date(timeIntervalSince1970: 1_699_000_000),
            modified: Date(timeIntervalSince1970: 1_700_000_000),
            boundsInPageSpace: PDFRectValue(x: 0, y: 0, width: 10, height: 10)
        )
    }

    @Test("A Note's Properties tab has no derivation section; a measurement's keeps it")
    func noteHasNoDerivation() {
        let note = InspectorSelectionSummary(markups: [Self.summary(kind: .note)])
        // Old output: every Properties tab listed `.derivation`, a Note's included.
        #expect(!InspectorTab.propertiesSections(for: note).contains(.derivation))
        #expect(InspectorTab.propertiesSections(for: note)
            == [.measurement, .scale, .identity, .status, .layerZone, .customData, .actions])

        let area = InspectorSelectionSummary(markups: [Self.summary(kind: .measurement, measurementKind: .area)])
        #expect(InspectorTab.propertiesSections(for: area) == InspectorTab.propertiesSections)

        // A mixed selection keeps it (the section itself asks for a single measurement), and so
        // does nothing selected, which the panel shows its empty state for.
        let mixed = InspectorSelectionSummary(markups: note.markups + area.markups)
        #expect(InspectorTab.propertiesSections(for: mixed).contains(.derivation))
        #expect(InspectorTab.propertiesSections(for: InspectorSelectionSummary(markups: [])) == InspectorTab.propertiesSections)
    }
}
