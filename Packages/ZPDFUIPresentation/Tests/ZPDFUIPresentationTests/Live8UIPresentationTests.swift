import Foundation
import Testing
@testable import ZPDFUIPresentation

/// Live test 8, area "l8-appcore", the presentation half: L-99 (a Note logged as "Measured") and
/// L-102 (Radius on a sheet with separate X and Y scales said nothing until it failed).
@Suite("Live test 8 — presentation (L-99, L-102)")
struct Live8UIPresentationTests {

    @Test("L-99: a creation that measured nothing reads Added; a measurement still reads Measured")
    func addedIsNotMeasured() {
        let added = LedgerAuditEvent(sequence: 1, occurredAt: .distantPast, action: LedgerAuditEvent.markupAddedAction, actor: "A. Berg")
        let measured = LedgerAuditEvent(sequence: 2, occurredAt: .distantPast, action: "markup_created", actor: "A. Berg")
        // Old output: "markup_added" was unknown, and every creation was a "markup_created" row
        // reading "Measured" — a Note included.
        #expect(added.actionDisplayName == "Added")
        #expect(measured.actionDisplayName == "Measured")
    }

    @Test("L-102: the three circle tools need one scale for both directions; nothing else does")
    func circleToolsNeedAUniformScale() {
        #expect(Set(MeasurementKind.allCases.filter(\.needsUniformScale)) == [.radius, .diameter, .threePointCircle])
    }

    @Test("L-102: the refusal blocks Finish and says why in words, with its symbol")
    func refusalBlocksInWords() {
        let refusal = MeasurementWarningSummary.circleNeedsUniformScale
        #expect(refusal.isBlocking)
        #expect(refusal.symbolName == "exclamationmark.octagon")
        #expect(refusal.message == "This sheet has separate X and Y scales, so a circle drawn on it has no single radius. Calibrate one scale for both directions to measure circles.")
    }

    /// Re-fix: on a sheet where a Scale Region has one scale, a click outside it is refused with
    /// a sentence that does not tell the person to recalibrate a sheet that can already measure
    /// circles in part.
    @Test("L-102: the refusal where the scale is separate in X and Y blocks, in its own words")
    func refusalHereBlocksInWords() {
        let refusal = MeasurementWarningSummary.circleNeedsUniformScaleHere
        #expect(refusal.isBlocking)
        #expect(refusal.symbolName == "exclamationmark.octagon")
        #expect(refusal.message == "Here the sheet has separate X and Y scales, so a circle drawn here has no single radius. Draw circles where the sheet has one scale for both directions.")
        #expect(!refusal.message.contains("Calibrate"))
    }

    @Test("L-102: a presenter that names no restriction has none, so the armed note is unchanged")
    @MainActor
    func noRestrictionByDefault() {
        let presenter = MockMeasurementToolPresenter()
        presenter.activate(kind: .radius)
        #expect(presenter.toolRestrictionNote == nil)
        #expect(presenter.armedToolNote == nil)
    }

    @Test("L-102: with no unavailable tool, the status note is the missing parameter, as before")
    @MainActor
    func armedToolNoteFallsBackToTheParameter() {
        let presenter = MockMeasurementToolPresenter()
        presenter.activate(kind: .volume)
        #expect(presenter.toolUnavailableReason == nil)
        #expect(presenter.armedToolNote != nil)
        #expect(presenter.armedToolNote == presenter.missingParameterNote)
        presenter.activate(kind: .length)
        #expect(presenter.armedToolNote == nil)
    }
}
