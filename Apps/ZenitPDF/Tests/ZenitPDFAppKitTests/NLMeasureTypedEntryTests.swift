import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// NL-MEASURE-18 on the canvas: typed length and angle place the next vertex through the scale,
/// and the live pill echoes the entry.
@MainActor
@Suite(.appTierSerialised)
struct NLMeasureTypedEntryTests {

    /// 1:100 → one inch of paper (72 pt) is 2.54 m. Typing "2,54<0" from (100, 300) places the
    /// next vertex at (172, 300); "1,27<90" then places (172, 336). The polylength is 3.81 m.
    @Test("2,54<0 then 1,27<90 places vertices 72 pt and 36 pt away; the pill echoes the entry")
    func typedSegments() async throws {
        let harness = try await NLMeasureR2Harness.make("Typed.pdf")
        defer { NLMeasureR2Harness.tearDown(harness) }
        let core = harness.core
        try await core.commands.setPresetScale(page: harness.page, ratioDenominator: 100)
        harness.shell.toolbar.activateMeasurement(.polylength)
        let canvas = try #require(harness.controller.canvasController(for: harness.document))
        canvas.refresh()
        #expect(await AppTestSupport.wait { core.measurement.activeKind == .polylength })
        // Without a placed point the digits are not claimed (they stay shortcuts).
        #expect(canvas.handle(key: .typed("4")) == false)
        canvas.placeTypedMeasurementPoint(PDFPointValue(x: 100, y: 300))
        #expect(await AppTestSupport.wait { core.measurement.placedPoints.count == 1 })

        for character in "2,54<0" { #expect(canvas.handle(key: .typed(character))) }
        #expect(canvas.typedEntry == "2,54<0")
        #expect(canvas.liveStateForTesting().drawing.caption == "2,54 m < 0° \u{23CE}")
        #expect(canvas.handle(key: .finish))
        #expect(await AppTestSupport.wait { core.measurement.placedPoints.count == 2 })
        let second = try #require(core.measurement.placedPoints.last)
        #expect(Swift.abs(second.x - 172) < 1e-9 && Swift.abs(second.y - 300) < 1e-9)
        #expect(canvas.typedEntry.isEmpty)

        // Delete edits the entry, Escape drops it, neither touches the shape.
        for character in "1,279" { _ = canvas.handle(key: .typed(character)) }
        #expect(canvas.handle(key: .removeLastVertex))
        #expect(canvas.typedEntry == "1,27")
        for character in "<90" { _ = canvas.handle(key: .typed(character)) }
        #expect(canvas.handle(key: .finish))
        #expect(await AppTestSupport.wait { core.measurement.placedPoints.count == 3 })
        let third = try #require(core.measurement.placedPoints.last)
        #expect(Swift.abs(third.x - 172) < 1e-9 && Swift.abs(third.y - 336) < 1e-9)

        _ = canvas.handle(key: .typed("7"))
        #expect(canvas.handle(key: .escape))
        #expect(canvas.typedEntry.isEmpty)
        #expect(core.measurement.placedPoints.count == 3)

        // An unreadable entry keeps the text to correct and places nothing.
        for character in "4//" { _ = canvas.handle(key: .typed(character)) }
        _ = canvas.handle(key: .finish)
        #expect(canvas.typedEntry == "4//")
        #expect(core.measurement.placedPoints.count == 3)
    }

    @Test("Feet and inches and plain numbers parse; the unit is the display unit")
    func grammar() {
        let metres = PDFCanvasViewController.parseTypedSegment("4,2", unit: .metre)
        #expect(metres?.metres == Decimal(string: "4.2")!)
        // 12'6" = 150 in = 3.81 m exactly.
        #expect(PDFCanvasViewController.parseTypedSegment("12'6\"", unit: .foot)?.metres == Decimal(string: "3.81")!)
        let angled = PDFCanvasViewController.parseTypedSegment("4200<45", unit: .millimetre)
        #expect(angled?.metres == Decimal(string: "4.2")! && angled?.angleDegrees == 45)
    }
}
