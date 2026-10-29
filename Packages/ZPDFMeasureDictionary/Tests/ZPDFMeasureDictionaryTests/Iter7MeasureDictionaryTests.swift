import CoreGraphics
import Foundation
import Testing
@testable import ZPDFMeasureDictionary

/// X-052: the ratio a viewport stands for on a `/UserUnit` page, divided in one place.
@Suite("PDF measure dictionaries — iteration 7")
struct Iter7MeasureDictionaryTests {

    /// A whole-page viewport whose factor is 1:200 per default user-space unit: one point is
    /// 200 × 0.0254 / 72 = 0.0705555… m.
    static let oneTwoHundred = "<< /Type /Viewport /Measure << /Type /Measure /Subtype /RL /R (1:200) "
        + "/X [<< /Type /NumberFormat /U (m) /C 0.0705555555556 >>] >> >>"

    /// Hand-derived: on a `/UserUnit 2` page a preset 1:N measures 2·N·0.0254/72 m per point, so
    /// the ratio that matches 0.0705555… m per point is 1:100; on `/UserUnit 4`, 1:50. A unit the
    /// specification would not accept reads as its default, 1.
    @Test("X-052: the viewport's ratio divides by the page's user unit, once")
    func ratioOnAUserUnitPage() throws {
        let viewport = try #require(PDFMeasureReader.viewports(in: PDFMeasureReaderTests.pdf(viewports: Self.oneTwoHundred)).first)
        #expect(viewport.ratioDenominator == 200)
        #expect(viewport.ratioDenominator(userUnit: 1) == 200)
        #expect(viewport.ratioDenominator(userUnit: 2) == 100)
        #expect(viewport.ratioDenominator(userUnit: 4) == 50)
        for unusable in [0.0, -2, .nan, .infinity] {
            #expect(viewport.ratioDenominator(userUnit: unusable) == 200, "\(unusable)")
        }
    }
}
