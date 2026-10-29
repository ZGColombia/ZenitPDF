import Foundation
import Testing
@testable import ZPDFUIPresentation

/// The ADR-0007 presentation surface: the audit filter's semantics, the mock trail's
/// shape, and the derivation model the inspector binds to.
@MainActor
@Suite("Audit presenting")
struct AuditPresentingTests {

    private let presenter = MockLedgerPresenter()

    @Test("An empty filter passes everything; each field narrows independently")
    func filterSemantics() {
        let all = presenter.auditEvents(matching: LedgerAuditFilter())
        #expect(!all.isEmpty)

        let page = presenter.auditPageLabels.first
        #expect(page != nil)
        let byPage = presenter.auditEvents(matching: LedgerAuditFilter(pageLabel: page))
        #expect(!byPage.isEmpty)
        #expect(byPage.allSatisfy { $0.pageLabel == page })
        #expect(byPage.count < all.count)

        let byAction = presenter.auditEvents(matching: LedgerAuditFilter(action: "scale_changed"))
        #expect(byAction.allSatisfy { $0.action == "scale_changed" })
        #expect(byAction.count == 1)

        let markup = all.compactMap(\.markupID).first
        let byMarkup = presenter.auditEvents(matching: LedgerAuditFilter(markupID: markup))
        #expect(!byMarkup.isEmpty)
        #expect(byMarkup.allSatisfy { $0.markupID == markup })
    }

    @Test("The trail is sequence-ordered and gapless, like the table it mirrors")
    func trailOrdering() {
        let all = presenter.auditEvents(matching: LedgerAuditFilter())
        #expect(all.map(\.sequence) == Array(1...all.count))
    }

    @Test("A scale change fans out over one shared undo group (ADR-0007 §2)")
    func scaleChangeFanOut() {
        let all = presenter.auditEvents(matching: LedgerAuditFilter())
        let group = all.filter { $0.undoGroup == "sample-scale-change" }
        #expect(group.contains { $0.action == "scale_changed" && $0.markupID == nil })
        #expect(group.contains { $0.action == "markup_rescaled" && $0.markupID != nil })
    }

    @Test("Every sample markup in the trail has a derivation with history attached")
    func derivationForMarkup() throws {
        let all = presenter.auditEvents(matching: LedgerAuditFilter())
        let markupID = try #require(all.compactMap(\.markupID).first)
        let model = try #require(presenter.derivation(for: markupID))
        #expect(model.hasProvenance)
        #expect(model.sections.contains { $0.key == "scale" })
        #expect(model.sections.contains { $0.key == "values" })
        // The raw SI value and the display rounding are separate facts (ADR-0007 §1).
        let values = try #require(model.sections.first { $0.key == "values" })
        #expect(values.facts.contains { $0.key.hasSuffix(".si") })
        #expect(values.facts.contains { $0.key.hasSuffix(".display") })
        #expect(!model.history.isEmpty)
        #expect(model.history.allSatisfy { $0.markupID == markupID })

        #expect(presenter.derivation(for: UUID()) == nil)
    }

    @Test("Known actions read as words; unknown actions stay honest raw values")
    func actionDisplayNames() {
        let known = LedgerAuditEvent(
            sequence: 1, occurredAt: .distantPast, action: "markup_rescaled", actor: "a"
        )
        #expect(known.actionDisplayName == "Rescaled")
        let unknown = LedgerAuditEvent(
            sequence: 2, occurredAt: .distantPast, action: "markup_teleported", actor: "a"
        )
        #expect(unknown.actionDisplayName == "markup_teleported")
    }

    @Test("An undo reads 'Undone' and a redo reads 'Redone' — never the same word twice")
    func undoAndRedoAreLabelledApart() {
        let undone = LedgerAuditEvent(
            sequence: 1, occurredAt: .distantPast, action: "compensated", actor: "a"
        )
        #expect(undone.actionDisplayName == "Undone")
        let redone = LedgerAuditEvent(
            sequence: 2, occurredAt: .distantPast, action: "recompensated", actor: "a"
        )
        #expect(redone.actionDisplayName == "Redone")
    }
}
