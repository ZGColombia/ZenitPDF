import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// nl-markup's bug list: each test fails on the code
/// before the fix, and the comment says what the old code produced.
@MainActor
@Suite(.appTierSerialised, .serialized)
struct NLMarkupBugTests {

    private static let pageID = UUID()

    private static func record(
        _ kind: ZPDFContracts.MarkupKind,
        geometry: MeasurementGeometry,
        style: MarkupStyle = MarkupStyle(),
        caption: String? = nil
    ) -> MarkupRecord {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        return MarkupRecord(
            id: MarkupID(UUID()),
            documentID: DocumentID(UUID()),
            pageID: PageID(pageID),
            kind: kind,
            style: style,
            caption: caption,
            geometry: geometry,
            createdAt: now,
            modifiedAt: now
        )
    }

    private static func ring(_ points: [(Double, Double)]) -> MeasurementGeometry {
        MeasurementGeometry(
            pageID: PageID(pageID),
            polygons: [PolygonGeometry(outer: PolygonRing(
                points: points.map { PDFPoint(x: $0.0, y: $0.1) }, isClosed: true
            ))]
        )
    }

    private static func points(_ points: [(Double, Double)]) -> MeasurementGeometry {
        MeasurementGeometry(pageID: PageID(pageID), points: points.map { PDFPoint(x: $0.0, y: $0.1) })
    }

    private static func shape(of record: MarkupRecord) throws -> CanvasMarkupShape {
        try #require(CanvasSceneBuilder.build(records: [record], summaries: [], pageID: pageID).first)
    }

    // MARK: - BUG: "Cloud" line style did nothing on rectangles, polygons and ellipses

    @Test("Cloud on a rectangle draws scallops (old: the 4-corner ring, drawn solid)")
    func cloudOnRectangle() throws {
        var style = MarkupStyle()
        style.lineStyle = .cloud
        let rectangle = Self.record(.rectangle, geometry: Self.ring([(0, 0), (240, 0), (240, 120), (0, 120)]), style: style)
        let stroke = try #require(try Self.shape(of: rectangle).strokes.first)
        // Old code: 4 points. The cloud rule gives an 18 pt scallop radius here (240 / 12 = 20,
        // capped at 18), so each 240 pt edge takes round(240 / 36) = 7 bumps and each 120 pt
        // edge round(120 / 36) = 3, 12 samples per bump: (7 + 3 + 7 + 3) × 12 = 240 points.
        #expect(stroke.points.count == 240)
        #expect(stroke.closed)
        // A bump is a semicircle on its chord: 240 / 7 ≈ 34.3 pt chords bulge 17.1 pt, 120 / 3 =
        // 40 pt chords bulge 20 pt, so nothing reaches more than 20 pt outside the ring.
        #expect(stroke.points.allSatisfy { $0.x >= -20.000001 && $0.x <= 260.000001 && $0.y >= -20.000001 && $0.y <= 140.000001 })
        #expect(stroke.points.contains { $0.y < -1 }, "the bottom edge bulges outward (below y = 0)")
    }

    @Test("Cloud on a polygon draws scallops (old: the 3-point ring)")
    func cloudOnPolygon() throws {
        var style = MarkupStyle()
        style.lineStyle = .cloud
        let polygon = Self.record(.polygon, geometry: Self.ring([(0, 0), (120, 0), (60, 90)]), style: style)
        let stroke = try #require(try Self.shape(of: polygon).strokes.first)
        #expect(stroke.points.count > 3)
        #expect(stroke.points.count % 12 == 0, "whole bumps of 12 samples each")
    }

    @Test("Cloud on an ellipse draws scallops (old: the plain 72-point outline)")
    func cloudOnEllipse() throws {
        var style = MarkupStyle()
        style.lineStyle = .cloud
        let ellipse = Self.record(.ellipse, geometry: Self.points([(0, 0), (200, 100)]), style: style)
        let stroke = try #require(try Self.shape(of: ellipse).strokes.first)
        #expect(stroke.points.count != 72)
        #expect(stroke.points.count % 12 == 0)
        // A solid ellipse is unchanged.
        let plain = Self.record(.ellipse, geometry: Self.points([(0, 0), (200, 100)]))
        #expect(try Self.shape(of: plain).strokes.first?.points.count == 72)
    }

    @Test("A measurement's outline is never reshaped by the Cloud style")
    func cloudLeavesMeasurementsAlone() throws {
        var style = MarkupStyle()
        style.lineStyle = .cloud
        let area = Self.record(.measurement, geometry: Self.ring([(0, 0), (100, 0), (100, 100), (0, 100)]), style: style)
        #expect(try Self.shape(of: area).strokes.first?.points.count == 4)
    }

    // MARK: - BUG: stored line ends were never drawn (arrowheads decided by kind)

    @Test("A line's stored ends reach the scene (old: none; the head came from kind == .arrow)")
    func lineEndsFromStyle() throws {
        var style = MarkupStyle()
        style.startCap = .circle
        style.endCap = .closedArrow
        let line = Self.record(.line, geometry: Self.points([(0, 0), (100, 0)]), style: style)
        let stroke = try #require(try Self.shape(of: line).strokes.first)
        // Old code: `arrowAtEnd == false` and no caps at all for a Line.
        #expect(stroke.startCap == .circle)
        #expect(stroke.drawnEndCap == .closedArrow)
    }

    @Test("An arrow set to none/none draws a plain line (old: a filled head, always)")
    func arrowWithoutEnds() throws {
        let arrow = Self.record(.arrow, geometry: Self.points([(0, 0), (100, 0)]), style: MarkupStyle())
        let stroke = try #require(try Self.shape(of: arrow).strokes.first)
        #expect(stroke.drawnEndCap == .none)
        #expect(stroke.startCap == .none)
        // An arrow drawn today stores a closed end, so it keeps the look it always had.
        let drawn = AppMarkupToolPresenter.markupStyle(kind: .arrow, style: .zenitInk)
        #expect(drawn.endCap == .closedArrow)
    }

    @Test("Each stored end has a painter, centred on the end point")
    func endPainters() throws {
        let tip = CGPoint(x: 100, y: 50)
        let previous = CGPoint(x: 0, y: 50)
        for cap in ZPDFContracts.LineCapStyle.allCases {
            let path = CanvasLineEnds.path(cap, from: previous, to: tip, strokeWidth: 2)
            if cap == .none || cap == .butt {
                #expect(path == nil, "\(cap) draws nothing")
                continue
            }
            let bounds = try #require(path?.bounds, "\(cap) has no painter")
            #expect(bounds.width > 1 && bounds.height > 1 || cap == .slash, "\(cap) is visible")
            #expect(bounds.insetBy(dx: -0.01, dy: -0.01).contains(tip) || cap == .openArrow || cap == .closedArrow,
                    "\(cap) sits on the end point")
            #expect(bounds.maxX <= tip.x + 10, "\(cap) does not run far past the end")
        }
    }

    // MARK: - BUG: stored font and alignment were ignored

    @Test("The stored font family and alignment reach the scene (old: system font, leading)")
    func fontAndAlignmentFromStyle() throws {
        var style = MarkupStyle()
        style.fontName = "Times New Roman"
        style.textAlignment = .center
        let text = Self.record(.text, geometry: Self.points([(0, 0), (200, 40)]), style: style, caption: "Note")
        let shape = try Self.shape(of: text)
        #expect(shape.fontName == "Times New Roman")
        #expect(shape.textAlignment == .center)
        // The canvas resolves the family, not the system font it used to draw.
        let font = CanvasMarkupFont.font(named: shape.fontName, size: 12)
        #expect(font.familyName == "Times New Roman")
        #expect(font.familyName != NSFont.systemFont(ofSize: 12).familyName)
        #expect(CanvasMarkupFont.alignment(.center) == .center)
        // A missing family falls back to the system font rather than drawing nothing.
        #expect(CanvasMarkupFont.font(named: "No Such Family 42", size: 12).familyName == NSFont.systemFont(ofSize: 12).familyName)
    }

    // MARK: - BUG: `placeStamp` was never called

    private static func promptedPreset() -> ToolPresetSummary {
        ToolPresetSummary(
            id: UUID(),
            name: "Checked",
            category: "Review",
            panel: .myTools,
            markupKind: .stamp,
            colorRGBA: ColorRGBA(red: 0.8, green: 0.1, blue: 0.1),
            defaultSubject: "Review",
            stamp: StampTemplate(
                id: UUID(),
                revision: 1,
                widthPoints: 160,
                heightPoints: 60,
                fields: [
                    StampFieldDefinition(
                        kind: .freeText,
                        prompt: "Checked by",
                        normalizedFrame: PDFRectValue(x: 0.05, y: 0.5, width: 0.9, height: 0.4)
                    )
                ]
            )
        )
    }

    @Test("A single-click stamp asks its questions and freezes the answer (old: blank, never asked)")
    func singleClickStampAsks() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "Stamp Prompt.pdf")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try AppTestSupport.makeDocument(opening: url)
        defer { document.close() }
        document.makeWindowControllers()
        let controller = try #require(document.windowControllers.first as? ProjectWindowController)
        #expect(await AppTestSupport.wait { document.core != nil })
        let core = try #require(document.core)
        let canvas = try #require(controller.canvasController(for: document))
        let preset = Self.promptedPreset()

        ZenitModalPresenter.reset()
        defer { ZenitModalPresenter.reset(); StampPlacementAsk.typeForTesting = nil }

        // Cancel places nothing.
        ZenitModalPresenter.handler = { _ in .button(1) }
        canvas.handlePresetPlaceClick(preset, at: PDFPointValue(x: 200, y: 300))
        #expect(ZenitModalPresenter.didRequest(StampPlacementAsk.modalIdentifier))
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(core.snapshot.markups.contains { $0.kind == .stamp } == false)

        // Place Stamp with a typed answer freezes it into the stamp.
        StampPlacementAsk.typeForTesting = { fields in fields.first?.stringValue = "  A. Berg " }
        ZenitModalPresenter.handler = { _ in .button(0) }
        canvas.handlePresetPlaceClick(preset, at: PDFPointValue(x: 200, y: 300))
        #expect(await AppTestSupport.wait { core.snapshot.markups.contains { $0.kind == .stamp } })
        let stampID = try #require(core.snapshot.markups.first { $0.kind == .stamp }?.id)
        let record = try #require(await core.session.markup(MarkupID(stampID)))
        #expect(record.stamp?.fields.map(\.resolvedText).contains("A. Berg") == true)
        #expect(ZenitModalPresenter.presentedForReal.isEmpty)
    }

    @Test("The prompt's answers are keyed by slot and trimmed")
    func promptAnswers() {
        let prompts = [StampPlacementPrompt(slot: 0, prompt: "Checked by"), StampPlacementPrompt(slot: 1, prompt: "Note")]
        let answers = StampPlacementAsk.answers(from: [" A ", "B"], prompts: prompts)
        #expect(answers.map(\.slot) == [0, 1])
        #expect(answers.map(\.value) == ["A", "B"])
        let (alert, fields) = StampPlacementAsk.makeAlert(presetName: "Checked", prompts: prompts)
        #expect(fields.count == 2)
        #expect(alert.buttons.count == 2)
    }
}
