import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// NL-MEASURE-07 through the shipping window: the Inspector offers the selected volume's depth,
/// a commit recomputes it as one undo step, and Pick Fall Line sets the slope's direction.
@MainActor
@Suite(.appTierSerialised)
struct NLMeasureInspectorParameterTests {

    /// 1:100 → 72 pt = 2.54 m. A 72 × 72 pt slab is 2.54² = 6.4516 m²; at 200 mm it holds
    /// 1.29032 m³ and at 250 mm 1.6129 m³ (hand-derived).
    @Test("Depth 200 → 250 mm in the Inspector recomputes the volume; one undo restores it")
    func depthRow() async throws {
        let harness = try await NLMeasureR2Harness.make("Slab.pdf")
        defer { NLMeasureR2Harness.tearDown(harness) }
        let core = harness.core
        try await core.commands.setPresetScale(page: harness.page, ratioDenominator: 100)
        var parameters = MeasurementParameters.default
        parameters.depth = .length(Decimal(string: "0.2")!)
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let slab = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: DocumentID(UUID()), pageID: harness.page, kind: .measurement, tool: .volume,
            subject: "Slab", author: "t",
            geometry: MeasurementGeometry(pageID: harness.page, polygons: [PolygonGeometry(outer: PolygonRing(points: [
                PDFPoint(x: 100, y: 100), PDFPoint(x: 172, y: 100), PDFPoint(x: 172, y: 172), PDFPoint(x: 100, y: 172)
            ]))]),
            parameters: parameters, createdAt: stamp, modifiedAt: stamp
        )
        try await core.commands.perform(.addMarkup(slab))
        core.canvas.select(markupIDs: [slab.id.rawValue], additive: false)
        let editing = harness.shell.inspectorEditing
        #expect(await AppTestSupport.wait { editing.parameterRowsSelection == [slab.id.rawValue] && !editing.parameterRows.isEmpty })
        let depth = try #require(editing.parameterRows.first { $0.id == "depth" })
        #expect(depth.text == "0.2" || depth.text == "200", "shown in the display unit")
        let unitIsMillimetre = depth.unitSymbol == "mm"
        editing.onEditParameter?([slab.id.rawValue], "depth", unitIsMillimetre ? "250" : "0.25")
        var volume: Decimal?
        for _ in 0..<100 {
            volume = await core.session.markup(slab.id)?.measurement?[.volume]?.value
            if let volume, volume > 1.5 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let expected = 1.6129
        let got = NSDecimalNumber(decimal: try #require(volume)).doubleValue
        #expect(Swift.abs(got - expected) <= expected * 1e-12)
        await core.commands.undo()
        let restored = NSDecimalNumber(decimal: try #require(await core.session.markup(slab.id)?.measurement?[.volume]?.value)).doubleValue
        #expect(Swift.abs(restored - 1.29032) <= 1.29032 * 1e-12)

        // Unreadable text is refused in words and changes nothing.
        editing.onEditParameter?([slab.id.rawValue], "slope", "steep")
        #expect(await AppTestSupport.wait { editing.parameterRefusal != nil })

        // Pick Fall Line: two clicks, low then high, set the direction (90°: straight up the page).
        var roofParameters = MeasurementParameters.default
        roofParameters.slope = .uniformPlane(.riseOverRun(rise: 6, run: 12))
        var roof = slab
        roof.id = MarkupID(UUID())
        roof.tool = .trueSlopedArea
        roof.parameters = roofParameters
        try await core.commands.perform(.addMarkup(roof))
        editing.onPickFallLine?([roof.id.rawValue])
        #expect(FallLinePick.isArmed(harness.document))
        harness.controller.finishCalibration(points: [PDFPointValue(x: 120, y: 110), PDFPointValue(x: 120, y: 160)], for: harness.document)
        var azimuth: Decimal?
        for _ in 0..<100 {
            azimuth = await core.session.markup(roof.id)?.parameters?.slope.azimuth?.degrees
            if azimuth != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(azimuth == 90, "\(core.document.warnings.map { $0.title + " " + $0.message }) note: \(String(describing: core.status.snapshot.activeToolNote))")
    }
}
