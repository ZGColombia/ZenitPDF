import CoreGraphics
import CryptoKit
import Foundation
import Testing
@testable import ZPDFTestingSupport

/// The synthetic drawing sheets agree with their own design: the bytes are the pinned identity,
/// the drawing emits exactly the hand-counted primitives, and the parts the consumer tests lean
/// on — the free band, the ruler, the title-block runs — are where `SyntheticRoofPlan` says.
@Suite("Synthetic Roof Plan")
struct SyntheticRoofPlanTests {

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-synthetic-roof-plan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("The roof plan's bytes are the pinned, versioned identity")
    func identityIsPinned() throws {
        let fixture = try ZPDFFixtures.data(.syntheticRoofPlan)
        let digest = SHA256.hash(data: fixture.data).map { String(format: "%02x", $0) }.joined()
        print("SYNTHETIC-ROOF-PLAN identity=\(SyntheticRoofPlan.identityName) sha256=\(digest) bytes=\(fixture.data.count)")
        #expect(digest == SyntheticRoofPlan.sha256, "bump SyntheticRoofPlan.version and re-pin after a byte change")
        #expect(fixture.data.count == SyntheticRoofPlan.byteCount)
    }

    @Test("The drawing emits exactly the hand-counted primitives, part by part")
    func primitiveArithmetic() throws {
        // 5 + 13 + 12 + 50 + 9 + 14085 + 6 + 10 + 5 + 262 + 25 + 24 + 8 + 9 + 1694 + 124 = 16341,
        // the sum of the parts listed in `SyntheticRoofPlanFixtures.primitiveCounts`.
        #expect(SyntheticRoofPlanFixtures.roofPlanPrimitiveCount == 16_341)
        #expect(try ZPDFFixtures.manifest(for: .syntheticRoofPlan).vectorPrimitiveCount == 16_341)
        // The generator's own tally, kept while it wrote the content stream.
        let drawn = try SyntheticRoofPlanFixtures.roofPlanContent(kind: .syntheticRoofPlan)
        #expect(drawn.emitted == 16_341)
        // The parts that are counts of construction, re-derived here from their definitions.
        #expect(SyntheticRoofPlan.glyphBases.count == SyntheticRoofPlan.glyphCount)
        let counts = SyntheticRoofPlan.horizontalAxes.map { SyntheticRoofPlan.axisElements(from: $0.from, to: $0.to).count }
        // 640 pt = exactly 20 periods of 32 pt, two elements a period.
        #expect(counts == [40, 40, 40])
        let vertical = SyntheticRoofPlan.axisElements(from: 230, to: 1370)
        // 1140 pt = 35 periods (70 elements) + one whole 20 pt dash.
        #expect(vertical.count == 71)
        #expect(vertical.last.map { $0.end - $0.start } == 20)
    }

    @Test("Every hatch glyph lies inside one face of the annex: 4 pt from its outline, 0.5 pt clear of each hip")
    func hatchStaysInside() {
        let roof = SyntheticRoofPlan.sedumRoof
        // Signed distances from the hip lines, by the point-to-line formula rather than by the
        // s / u bands the generator uses, so the two must agree independently.
        func distance(_ p: FixturePoint, _ a: FixturePoint, _ b: FixturePoint) -> Double {
            let dx = b.x - a.x, dy = b.y - a.y
            return (dx * (p.y - a.y) - dy * (p.x - a.x)) / (dx * dx + dy * dy).squareRoot()
        }
        let lower = SyntheticRoofPlan.sedumLowerHip, upper = SyntheticRoofPlan.sedumUpperHip
        var lattice = 0, drawn = 0
        for row in 0..<198 {
            for column in 0..<24 {
                let base = FixturePoint((row % 2 == 0 ? 467 : 475.5) + 17 * Double(column), 305 + 5 * Double(row))
                lattice += 1
                #expect(base.x - 2.125 >= roof.llx + 4 && base.x + 2.125 <= roof.urx - 4)
                #expect(base.y >= roof.lly + 4 && base.y + 2.5 <= roof.ury - 4)
                let points = [base] + SyntheticRoofPlan.glyphProngs.map { base + $0 }
                let clear = [lower, upper].allSatisfy { hip in
                    let sides = points.map { distance($0, hip.start, hip.end) }
                    return sides.allSatisfy { $0 >= 0.5 } || sides.allSatisfy { $0 <= -0.5 }
                }
                #expect(clear == SyntheticRoofPlan.glyphIsDrawn(base), "\(base)")
                if clear { drawn += 1 }
            }
        }
        #expect(lattice == 4_752)
        #expect(drawn == 4_695, "57 lattice points sit within 0.5 pt of a hip line")
    }

    @Test("No grid-axis element ends within 4 pt of a boundary line, past the 3 pt bridging tolerance")
    func axisEndsClearOfBoundaries() {
        func distance(_ p: FixturePoint, _ a: FixturePoint, _ b: FixturePoint) -> Double {
            let dx = b.x - a.x, dy = b.y - a.y
            let t = Swift.max(0, Swift.min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / (dx * dx + dy * dy)))
            return ((p.x - a.x - t * dx) * (p.x - a.x - t * dx) + (p.y - a.y - t * dy) * (p.y - a.y - t * dy)).squareRoot()
        }
        let e = SyntheticRoofPlan.eave, g = SyntheticRoofPlan.snowGuard, s = SyntheticRoofPlan.sedumRoof
        func rect(_ r: FixtureRect) -> [(FixturePoint, FixturePoint)] {
            let c = r.counterClockwiseCorners
            return [(c[0], c[1]), (c[1], c[2]), (c[2], c[3]), (c[3], c[0])]
        }
        let boundaries = rect(e) + rect(g) + rect(s) + [
            (FixturePoint(900, 300), SyntheticRoofPlan.ridgeFoot), (FixturePoint(1500, 300), SyntheticRoofPlan.ridgeFoot),
            (FixturePoint(900, 1300), SyntheticRoofPlan.ridgeHead), (FixturePoint(1500, 1300), SyntheticRoofPlan.hipKink),
            (SyntheticRoofPlan.hipKink, SyntheticRoofPlan.ridgeHead), (SyntheticRoofPlan.ridgeFoot, SyntheticRoofPlan.ridgeHead),
            (SyntheticRoofPlan.snowGuardStub.start, SyntheticRoofPlan.snowGuardStub.end)
        ]
        var ends: [FixturePoint] = []
        for axis in SyntheticRoofPlan.horizontalAxes {
            for element in SyntheticRoofPlan.axisElements(from: axis.from, to: axis.to) {
                ends += [FixturePoint(element.start, axis.y), FixturePoint(element.end, axis.y)]
            }
        }
        for axis in SyntheticRoofPlan.verticalAxes {
            for element in SyntheticRoofPlan.axisElements(from: axis.from, to: axis.to) {
                ends += [FixturePoint(axis.x, element.start), FixturePoint(axis.x, element.end)]
            }
        }
        let nearest = ends.map { end in boundaries.map { distance(end, $0.0, $0.1) }.min() ?? .infinity }.min() ?? 0
        #expect(nearest >= 4 - 1e-9, "\(nearest)")
    }

    @Test("The free measuring band is at least 40 pt from every drawn point but the title-column divider")
    func freeBandIsClear() throws {
        let band = SyntheticRoofPlan.freeBand
        // East of the house: the horizontal axes' label circles end by x = 1557.25 + 20 + 12 =
        // 1589.25, the east fence at x = 1675; the north arrow's ring reaches x = 1662 but only
        // above y = 1510. The title column starts at x = 2050, 5 pt east of the band.
        for axis in SyntheticRoofPlan.horizontalAxes {
            #expect(axis.to + 20 + SyntheticRoofPlan.axisLabelRadius <= band.llx - 40)
            #expect(axis.to + 20 + SyntheticRoofPlan.axisLabelRadius < SyntheticRoofPlan.eastFence.from - 3, "the label circle stays off the fence")
        }
        #expect(SyntheticRoofPlan.eave.urx <= band.llx - 40)
        #expect(SyntheticRoofPlan.eastFence.to <= band.llx - 40)
        #expect(1540 - 30 >= band.ury + 40, "the north arrow's ring is above the band")
        #expect(SyntheticRoofPlan.titleColumnLeft - band.urx == 5)
        #expect(SyntheticRoofPlan.rulerLeft.y + SyntheticRoofPlan.rulerTickHeight < band.lly - 40)
    }

    @Test("The ruler is 100 mm of paper: 36000/127 pt, eleven ticks 10 mm apart")
    func rulerIsOneHundredMillimetres() {
        let length = SyntheticRoofPlan.rulerRight.x - SyntheticRoofPlan.rulerLeft.x
        #expect(abs(length - 100 * 72 / 25.4) < 1e-12)
        #expect(SyntheticRoofPlan.rulerTickXs.count == 11)
        #expect(SyntheticRoofPlan.rulerTickXs.first == SyntheticRoofPlan.rulerLeft.x)
        #expect(SyntheticRoofPlan.rulerTickXs.last == SyntheticRoofPlan.rulerRight.x)
    }

    @Test("The only ratios on the sheet are the SKALA field's 1:50 and the area field's 1:10")
    func onlyTwoRatios() {
        let texts = SyntheticRoofPlan.titleRuns.map(\.text) + SyntheticRoofPlan.noteLines
            + SyntheticRoofPlan.roofAnnotations.map(\.text)
        let ratios = texts.filter { $0.range(of: #"\d\s*:\s*\d"#, options: .regularExpression) != nil }
        #expect(ratios == ["1:10 EXEMPELPARK", "1:50"])
    }

    @Test("The synthetic sheets open, with the stated pages and boxes", arguments: FixtureKind.syntheticSheets)
    func sheetsOpen(kind: FixtureKind) throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let handle = try ZPDFFixtures.make(kind, in: directory)
        let document = try #require(CGPDFDocument(handle.url as CFURL))
        #expect(document.numberOfPages == handle.manifest.pageCount)
        for (index, page) in handle.manifest.pages.enumerated() {
            let pdfPage = try #require(document.page(at: index + 1))
            let crop = pdfPage.getBoxRect(.cropBox)
            #expect(abs(crop.width - page.cropBox.width) < 1e-6 && abs(crop.height - page.cropBox.height) < 1e-6)
        }
    }

    @Test("The layered variant tags the hatch on L0 and the grid on L1, and nothing else")
    func layeredVariantTags() throws {
        // Count, inside each marked-content section of the generated stream, the painted paths
        // the way an extractor counts primitives: an open two-point stroke is one, a closed
        // four-curve circle five (its subpath and its curves).
        let data = try SyntheticRoofPlanFixtures.roofPlanContent(
            kind: .syntheticRoofPlanLayered,
            layers: SyntheticRoofPlanFixtures.LayerTags(hatch: "L0", axes: "L1")
        ).content.data(kind: .syntheticRoofPlanLayered)
        let text = String(decoding: data, as: UTF8.self)
        func primitives(in tag: String) throws -> Int {
            let start = try #require(text.range(of: "/OC /\(tag) BDC\n"))
            let end = try #require(text.range(of: "EMC\n", range: start.upperBound..<text.endIndex))
            let section = text[start.upperBound..<end.lowerBound]
            let lines = section.components(separatedBy: " l\nS\n").count - 1
            let circles = section.components(separatedBy: " c\nh\nS\n").count - 1
            return lines + 5 * circles
        }
        #expect(try primitives(in: "L0") == SyntheticRoofPlanFixtures.layeredHatchPrimitives)
        #expect(try primitives(in: "L1") == SyntheticRoofPlanFixtures.layeredGridPrimitives)
        #expect(SyntheticRoofPlanFixtures.layeredHatchPrimitives == 14_085)
        #expect(SyntheticRoofPlanFixtures.layeredGridPrimitives == 287)
        #expect(try ZPDFFixtures.manifest(for: .syntheticRoofPlanLayered).vectorPrimitiveCount == 16_341)
    }

    @Test("The run-length encoder round-trips")
    func runLengthRoundTrips() {
        let input: [UInt8] = [1, 1, 1, 2, 3, 4, 4, 5] + [UInt8](repeating: 9, count: 300) + (0..<200).map { UInt8($0 % 7) }
        let encoded = [UInt8](SyntheticRoofPlanFixtures.runLengthEncoded(input))
        var decoded: [UInt8] = []
        var index = 0
        while index < encoded.count, encoded[index] != 128 {
            let length = Int(encoded[index])
            if length < 128 {
                decoded += encoded[(index + 1)...(index + 1 + length)]
                index += length + 2
            } else {
                decoded += [UInt8](repeating: encoded[index + 1], count: 257 - length)
                index += 2
            }
        }
        #expect(decoded == input)
        #expect(encoded.last == 128)
    }
}
