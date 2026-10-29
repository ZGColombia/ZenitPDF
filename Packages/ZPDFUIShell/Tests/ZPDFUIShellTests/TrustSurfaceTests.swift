import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIShell

/// The S22 trust surfaces: the Inspector's derivation section and the History tab of the
/// bottom pane — the logic parts, asserted without a window.
@MainActor
@Suite("Trust surfaces", .shellTierSerialised)
struct TrustSurfaceTests {

    @Test("The shell's mock environment offers the audit surface the panes cast to")
    func environmentCarriesAuditPresenting() throws {
        let environment = ProjectShellEnvironment.mock()
        let audit = try #require(environment.ledger as? LedgerAuditPresenting)
        let events = audit.auditEvents(matching: LedgerAuditFilter())
        #expect(events.isEmpty == false)
    }

    @Test("The derivation section is a first-class Inspector section with a real title")
    func derivationSectionExists() {
        #expect(InspectorSection.allCases.contains(.derivation))
        #expect(InspectorSection.derivation.displayName == "How This Number Was Calculated")
        // Collapsed by default, like everything except Measurement.
        #expect(!InspectorSection.defaultExpanded.contains(.derivation))
    }

    @Test("Every derivation key the engine emits maps to wording, not to its raw key")
    func derivationFactLabels() {
        let engineKeys = [
            "geometry.digest", "geometry.capture",
            "scale.id", "scale.version", "scale.source",
            "scale.calibration.points", "scale.calibration.enteredLength", "scale.calibration.enteredUnit",
            "slope.mode", "slope.magnitude", "slope.azimuth",
            "parameters.depth", "parameters.height", "parameters.heightAtEnd",
            "parameters.volumeDepthReference", "parameters.cutoutPolicy",
            "parameters.perimeterPolicy", "parameters.openingAreas",
            "engine.formulaVersion", "engine.version", "engine.computedAt",
            "value.planArea.si", "value.planArea.display"
        ]
        for key in engineKeys {
            #expect(InspectorDerivationSection.factLabel(key) != key, "unmapped key \(key)")
        }
        // A key from a newer engine renders as itself rather than vanishing.
        #expect(InspectorDerivationSection.factLabel("value.futureField") == "value.futureField")
        // The raw SI value and the display rounding are labelled apart (ADR-0007 §1).
        // R-094: the quantity row's own field name, not a camel-case split of the key ("Plan
        // area", English only, in another case). X-037: the outline field `planArea` is named as
        // the ledger names it, "Gross Area", and the net field the Plan Area column reads is
        // "Plan Area" (old output: "Plan Area (exact)" for the gross field).
        #expect(InspectorDerivationSection.factLabel("value.planArea.si") == "Gross Area (exact)")
        #expect(InspectorDerivationSection.factLabel("value.planArea.display") == "Gross Area (shown as)")
        #expect(InspectorDerivationSection.factLabel("value.netArea.si") == "Plan Area (exact)")
    }

    @Test("Scale sources read as calibration words, never as enum cases")
    func scaleSourceWording() {
        let words = InspectorDerivationSection.factText(
            LedgerDerivationFact(key: "scale.source", value: "calibrationTwoPoint")
        )
        #expect(words == "calibrated from two points")
        let inherited = InspectorDerivationSection.factText(
            LedgerDerivationFact(key: "scale.source", value: "inherited")
        )
        #expect(inherited.contains("not calibrated"))
    }

    @Test("A change summary shows the movement, and a bare note falls back to the note")
    func changeSummaries() {
        // An entry written before display strings existed keeps its raw values — honest,
        // not blank.
        let change = LedgerAuditEvent(
            sequence: 1, occurredAt: .distantPast, action: "markup_modified", actor: "a",
            changes: [LedgerAuditValueChange(field: "planArea", before: "21.34", after: "25.5")]
        )
        #expect(InspectorDerivationSection.changeSummary(change) == "planArea 21.34 → 25.5")
        let note = LedgerAuditEvent(
            sequence: 2, occurredAt: .distantPast, action: "scale_changed", actor: "a",
            note: "scale 1:100 version 1 -> 2"
        )
        #expect(InspectorDerivationSection.changeSummary(note) == "scale 1:100 version 1 -> 2")
    }

    @Test("A summary reads like the ledger, not like a debugger")
    func changeSummariesUseDisplayStrings() {
        // An edit: before → after, in the ledger's own rendering.
        let edited = LedgerAuditEvent(
            sequence: 1, occurredAt: .distantPast, action: "markup_modified", actor: "a",
            changes: [LedgerAuditValueChange(
                field: "planLength", before: "5.03745704734261", after: "6.12244897959184",
                fieldDisplayName: "Plan Length", beforeDisplay: "5,04 m", afterDisplay: "6,12 m"
            )]
        )
        #expect(InspectorDerivationSection.changeSummary(edited) == "Plan Length 5,04 m → 6,12 m")

        // A creation: one value, no arrow from nowhere.
        let created = LedgerAuditEvent(
            sequence: 2, occurredAt: .distantPast, action: "markup_created", actor: "a",
            changes: [LedgerAuditValueChange(
                field: "planLength", before: nil, after: "5.03745704734261",
                fieldDisplayName: "Plan Length", beforeDisplay: nil, afterDisplay: "5,04 m"
            )]
        )
        #expect(InspectorDerivationSection.changeSummary(created) == "Plan Length 5,04 m")

        // A deletion: the value it went out with.
        let deleted = LedgerAuditEvent(
            sequence: 3, occurredAt: .distantPast, action: "markup_deleted", actor: "a",
            changes: [LedgerAuditValueChange(
                field: "planLength", before: "5.03745704734261", after: nil,
                fieldDisplayName: "Plan Length", beforeDisplay: "5,04 m", afterDisplay: nil
            )]
        )
        #expect(InspectorDerivationSection.changeSummary(deleted) == "Plan Length 5,04 m → —")
    }

    @Test("The bottom pane has exactly its two tabs, in mockup order")
    func paneTabs() {
        #expect(QuantityLedgerPane.PaneTab.allCases == [.quantities, .history])
        #expect(QuantityLedgerPane.PaneTab.quantities.title == "Quantities")
        #expect(QuantityLedgerPane.PaneTab.history.title == "History")
    }
}
