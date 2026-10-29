import Foundation
import Testing
import ZPDFContracts
import ZPDFUIPresentation
@testable import ZPDFAppCore

/// NL-MEASURE-07: depth, heights and slope edited on committed markups. Hand-derived at 1 m/pt.
@Suite("Inspector parameter editing (NL-MEASURE-07)")
struct NLMeasureParameterEditingTests {

    static let documentID = DocumentID(UUID())

    static func session() async throws -> (TakeoffSession, PageID) {
        let page = ZPDFContracts.PageDescriptor(id: PageID(UUID()), documentID: documentID, index: 0, label: "A",
                                                boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 1000, height: 1000)))
        let session = try TakeoffSession(documentID: documentID, pages: [page])
        _ = try await session.calibrate(page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0), knownLength: 100, knownLengthUnit: .metre)
        return (session, page.id)
    }

    static func square(_ page: PageID, tool: MeasurementTool, parameters: MeasurementParameters) -> ZPDFContracts.MarkupRecord {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        return ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: documentID, pageID: page, kind: .measurement, tool: tool, subject: "Slab", author: "t",
            geometry: MeasurementGeometry(pageID: page, polygons: [PolygonGeometry(outer: PolygonRing(points: [
                PDFPoint(x: 0, y: 0), PDFPoint(x: 10, y: 0), PDFPoint(x: 10, y: 10), PDFPoint(x: 0, y: 10)
            ]))]),
            parameters: parameters, createdAt: stamp, modifiedAt: stamp
        )
    }

    /// A 10 × 10 m slab, 200 mm → 250 mm: 100 × 0.2 = 20 m³ becomes 100 × 0.25 = 25 m³, one undo back.
    @Test("Depth 200 → 250 mm recomputes the volume; one undo restores it")
    func depth() async throws {
        let (session, page) = try await Self.session()
        var parameters = MeasurementParameters.default
        parameters.depth = .length(Decimal(string: "0.2")!)
        let slab = Self.square(page, tool: .volume, parameters: parameters)
        _ = try await session.apply(.addMarkup(slab))
        #expect(await session.markup(slab.id)?.measurement?[.volume]?.value == 20)

        let record = try #require(await session.markup(slab.id))
        let rows = ParameterEditing.rows(for: [record], lengthUnit: .millimetre)
        #expect(rows.map(\.kind) == [.depth, .slope], "a volume has a depth and a slope; no wall height")
        #expect(rows.first?.text == "200")
        #expect(rows.first?.unitSymbol == "mm")

        let commands = try ParameterEditing.commands(setting: .depth, to: "250", on: [record], lengthUnit: .millimetre)
        #expect(commands.count == 1)
        let outcome = try await session.applyBatch(commands)
        #expect(await session.markup(slab.id)?.parameters?.depth?.value == Decimal(string: "0.25")!)
        #expect(await session.markup(slab.id)?.measurement?[.volume]?.value == 25)
        _ = try await session.revert(outcome.inverse)
        #expect(await session.markup(slab.id)?.measurement?[.volume]?.value == 20)
    }

    /// True sloped area over 100 m² plan: at s = 0.5 the factor is √(1 + 0.25) = √1.25, so
    /// 100 √1.25 = 111.8033988749895 m². `6:12`, `50 %` and `0.5` are the same ratio exactly and
    /// give bit-identical results; `26.565051177077989°` is atan(0.5) and agrees within 1e-9.
    @Test("The slope accepts 6:12, 50 %, 0.5 (bit-identical) and degrees")
    func slopeForms() async throws {
        let (session, page) = try await Self.session()
        var parameters = MeasurementParameters.default
        parameters.slope = .uniformPlane(.percent(10))
        let roof = Self.square(page, tool: .trueSlopedArea, parameters: parameters)
        _ = try await session.apply(.addMarkup(roof))
        var results: [String: Decimal] = [:]
        for form in ["6:12", "50 %", "0.5", "26.565051177077989°"] {
            let record = try #require(await session.markup(roof.id))
            _ = try await session.applyBatch(try ParameterEditing.commands(setting: .slope, to: form, on: [record], lengthUnit: .metre))
            results[form] = try #require(await session.markup(roof.id)?.measurement?[.trueArea]?.value)
            #expect(ParameterEditing.rows(for: [try #require(await session.markup(roof.id))], lengthUnit: .metre).first { $0.kind == .slope }?.text != "")
        }
        #expect(results["6:12"] == results["50 %"])
        #expect(results["50 %"] == results["0.5"])
        let expected = 100 * (1.25).squareRoot()
        let exact = NSDecimalNumber(decimal: try #require(results["0.5"])).doubleValue
        #expect(Swift.abs(exact - expected) <= expected * 1e-12)
        let degrees = NSDecimalNumber(decimal: try #require(results["26.565051177077989°"])).doubleValue
        #expect(Swift.abs(degrees - expected) <= expected * 1e-9)
        #expect(ParameterEditing.slopeText(.riseOverRun(rise: 6, run: 12)) == "6:12")
    }

    @Test("A multi-selection is one step; mixed values show as mixed; bad text is refused")
    func multiSelection() async throws {
        let (session, page) = try await Self.session()
        var a = MeasurementParameters.default, b = MeasurementParameters.default
        a.depth = .length(Decimal(string: "0.1")!)
        b.depth = .length(Decimal(string: "0.3")!)
        let first = Self.square(page, tool: .volume, parameters: a)
        let second = Self.square(page, tool: .volume, parameters: b)
        _ = try await session.apply(.addMarkup(first))
        _ = try await session.apply(.addMarkup(second))
        let records = [try #require(await session.markup(first.id)), try #require(await session.markup(second.id))]
        let row = try #require(ParameterEditing.rows(for: records, lengthUnit: .metre).first { $0.kind == .depth })
        #expect(row.isMixed && row.text.isEmpty)
        let outcome = try await session.applyBatch(try ParameterEditing.commands(setting: .depth, to: "0,2", on: records, lengthUnit: .metre))
        #expect(await session.markup(first.id)?.measurement?[.volume]?.value == 20)
        #expect(await session.markup(second.id)?.measurement?[.volume]?.value == 20)
        _ = try await session.revert(outcome.inverse)
        #expect(await session.markup(first.id)?.measurement?[.volume]?.value == 10)
        #expect(await session.markup(second.id)?.measurement?[.volume]?.value == 30)

        #expect(throws: ParameterEditing.Refusal.unreadable("deep")) {
            _ = try ParameterEditing.commands(setting: .depth, to: "deep", on: records, lengthUnit: .metre)
        }
        #expect(throws: ParameterEditing.Refusal.notPositive) {
            _ = try ParameterEditing.commands(setting: .depth, to: "-1", on: records, lengthUnit: .metre)
        }
        // A wall and a volume share no parameter row.
        var wall = Self.square(page, tool: .wallArea, parameters: .default)
        wall.geometry = MeasurementGeometry(pageID: page, points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 10, y: 0)])
        #expect(ParameterEditing.rows(for: [records[0], wall], lengthUnit: .metre).map(\.kind) == [])
        #expect(ParameterEditing.rows(for: [wall], lengthUnit: .metre).map(\.kind) == [.height, .heightAtEnd])
    }

    /// Pick fall line: the direction (0,0) → (0,10) is 90°, the steepness is kept.
    @Test("Pick fall line sets the azimuth and keeps the steepness")
    func fallLine() async throws {
        let (session, page) = try await Self.session()
        var parameters = MeasurementParameters.default
        parameters.slope = .uniformPlane(.riseOverRun(rise: 6, run: 12))
        let roof = Self.square(page, tool: .trueSlopedArea, parameters: parameters)
        _ = try await session.apply(.addMarkup(roof))
        let record = try #require(await session.markup(roof.id))
        _ = try await session.applyBatch(try ParameterEditing.fallLineCommands(from: PDFPoint(x: 0, y: 0), to: PDFPoint(x: 0, y: 10), on: [record]))
        let slope = try #require(await session.markup(roof.id)?.parameters?.slope)
        #expect(slope.azimuth?.degrees == 90)
        #expect(slope.magnitude == .riseOverRun(rise: 6, run: 12))
    }
}
