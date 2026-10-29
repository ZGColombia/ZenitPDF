import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// NL-MEASURE-13 remainder: the canvas hatches the overlap, and the Settings switch turns the
/// guard off in every open document.
@MainActor
@Suite(.appTierSerialised)
struct NLMeasureDoubleCountHatchTests {

    static func area(_ harness: NLMeasureR2Harness.Harness, _ label: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> ZPDFContracts.MarkupRecord {
        let page = harness.page
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        return ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: DocumentID(UUID()), pageID: page, kind: .measurement, tool: .area,
            subject: "Floor finish", label: label, author: "t",
            geometry: MeasurementGeometry(pageID: page, polygons: [PolygonGeometry(outer: PolygonRing(points: [
                PDFPoint(x: x, y: y), PDFPoint(x: x + w, y: y), PDFPoint(x: x + w, y: y + h), PDFPoint(x: x, y: y + h)
            ]))]),
            createdAt: stamp, modifiedAt: stamp
        )
    }

    /// A = [100,300]², B = [250,450]×[100,300]: the hatch is [250,300]×[100,300].
    @Test("The overlap is hatched on the canvas; the Settings switch clears tray and hatch")
    func hatchAndSetting() async throws {
        let harness = try await NLMeasureR2Harness.make("Hatch.pdf")
        defer { NLMeasureR2Harness.tearDown(harness) }
        let core = harness.core
        try await core.commands.setPresetScale(page: harness.page, ratioDenominator: 100)
        try await core.commands.perform(.addMarkup(Self.area(harness, "A", 100, 100, 200, 200)))
        try await core.commands.perform(.addMarkup(Self.area(harness, "B", 250, 100, 200, 200)))
        await core.refreshDoubleCountWarnings(enabled: true)
        let canvas = try #require(harness.controller.canvasController(for: harness.document))
        #expect(await AppTestSupport.wait { !canvas.pageViewForTesting.doubleCountHatch.isEmpty })
        let ring = try #require(canvas.pageViewForTesting.doubleCountHatch.first)
        #expect(Set(ring.map { [$0.x, $0.y] }) == [[250, 100], [300, 100], [300, 300], [250, 300]])
        #expect(core.document.warnings.contains { $0.source == AppCoreEnvironment.doubleCountWarningSource })

        try ScratchDefaults.with(prefix: "zenit.r2measure.doublecount") { defaults, _ in
            ZenitSettingsWindowController.setDoubleCountGuard(false, defaults: defaults, documents: [harness.document])
            #expect(defaults.bool(forKey: AppCoreEnvironment.doubleCountGuardDefaultsKey) == false)
        }
        #expect(await AppTestSupport.wait { canvas.pageViewForTesting.doubleCountHatch.isEmpty })
        #expect(await AppTestSupport.wait {
            !core.document.warnings.contains { $0.source == AppCoreEnvironment.doubleCountWarningSource }
        })
    }
}
