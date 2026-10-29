import AppKit
import CoreGraphics
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFRasterAnalysis
import ZPDFUIPresentation
import ZPDFUIWorkflows
@testable import ZenitPDFAppKit

/// NL-AUTO-14, scan path: Create Symbol Schedule on a scanned sheet counts from the page picture.
/// The helpers are checked on hand-built pictures; the whole flow runs once over a real scan,
/// prompt and review answered by injection, nothing on screen.
@MainActor
@Suite("Scan symbol counting (NL-AUTO-14)", .appTierSerialised)
struct ScanSymbolCountTests {

    // MARK: - Helpers on hand-built pictures

    /// A 100 × 100 px picture of a 100 × 100 pt region at the origin (1 pt per pixel), white,
    /// with a black 10 × 6 px block whose top-left pixel is (20, 30).
    private func pictureWithBlock() -> GrayRaster {
        var pixels = [UInt8](repeating: 255, count: 100 * 100)
        for y in 30..<36 { for x in 20..<30 { pixels[y * 100 + x] = 0 } }
        return GrayRaster(width: 100, height: 100, pixels: pixels, pageRegion: CGRect(x: 0, y: 0, width: 100, height: 100))
    }

    @Test("The boxed example is trimmed to its ink plus a two-pixel margin")
    func templateIsTrimmed() throws {
        let raster = pictureWithBlock()
        // Rows 30–35 from the top are page y 70–64; the box (10, 55)–(45, 80) holds the block
        // with paper around it.
        let template = try #require(ScanSymbolCount.template(from: raster, box: PDFRectValue(x: 10, y: 55, width: 35, height: 25)))
        // 10 × 6 px of ink, plus 2 px either side: 14 × 10 px, which is 14 × 10 pt here.
        #expect(template.width == 14)
        #expect(template.height == 10)
        #expect(ScanSymbolCount.sizeInPoints(of: template) == CGSize(width: 14, height: 10))
        // Its centre is the block's: x 20…30 → 25, page y 64…70 → 67.
        #expect(abs(template.pageRegion.midX - 25) < 1e-9)
        #expect(abs(template.pageRegion.midY - 67) < 1e-9)
    }

    @Test("A box over blank paper or a speck is no example")
    func blankBoxIsRefused() {
        let raster = pictureWithBlock()
        #expect(ScanSymbolCount.template(from: raster, box: PDFRectValue(x: 60, y: 10, width: 30, height: 30)) == nil)
        var speck = [UInt8](repeating: 255, count: 100 * 100)
        for x in 50..<55 { speck[50 * 100 + x] = 0 } // 5 ink pixels, under the 12 needed.
        let specked = GrayRaster(width: 100, height: 100, pixels: speck, pageRegion: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(ScanSymbolCount.template(from: specked, box: PDFRectValue(x: 40, y: 40, width: 20, height: 20)) == nil)
    }

    private func match(_ x: Double, _ y: Double, score: Double, turns: Int = 0, mirrored: Bool = false) -> ScanSymbolCount.Found {
        ScanSymbolCount.Found(center: CGPoint(x: x, y: y), score: score, quarterTurns: turns, mirrored: mirrored)
    }

    @Test("Rows: matches ticked, weak scores near misses, counted places left alone, the example marked")
    func rowsAreClassified() {
        let rows = ScanSymbolCount.rows(
            matches: [
                match(100, 100, score: 0.95),
                match(300, 100, score: 0.65, turns: 1),
                match(500, 100, score: 0.9, mirrored: true)
            ],
            templateSize: CGSize(width: 20, height: 10),
            pageIndex: 2,
            pageLabel: "A-103",
            existing: [ExistingCountPoint(subject: "D-13", position: PDFPoint(x: 502, y: 101))],
            exemplarCenter: CGPoint(x: 101, y: 99),
            idBase: 7
        )
        #expect(rows.map(\.id) == [7, 8, 9])
        #expect(rows[0].status == .confirmed)
        #expect(rows[0].isExemplar)
        #expect(rows[0].isSelectedByDefault)
        // 0.65 is under the 0.7 bar and over the 0.6 floor: listed, unticked.
        #expect(rows[1].status == .nearMiss)
        #expect(!rows[1].isSelectedByDefault)
        // A quarter turn swaps the footprint: 10 wide, 20 high, centred on (300, 100).
        #expect(rows[1].bounds == PDFRectValue(x: 295, y: 90, width: 10, height: 20))
        // (502, 101) is 2.2 pt from the match, inside half the short side (5 pt).
        #expect(rows[2].status == .alreadyCounted(subject: "D-13"))
        #expect(!rows[2].isSelectedByDefault)
        #expect(rows.allSatisfy { $0.detail.hasPrefix("from the scan") })
        #expect(rows[1].detail.contains("turned 90°"))
        #expect(rows[2].detail.contains("mirrored"))
        #expect(rows[0].detail.contains("0.95"))
    }

    @Test("Landing: one markup per page, ticked rows only, the weakest ticked score as confidence")
    func landingsGroupByPage() {
        func row(_ id: Int, page: Int, x: Double) -> SymbolCountReviewRow {
            SymbolCountReviewRow(
                id: id, pageIndex: page, pageLabel: "P\(page)", position: PDFPointValue(x: x, y: 50),
                bounds: PDFRectValue(x: x - 5, y: 45, width: 10, height: 10), status: .confirmed, detail: "", isExemplar: false
            )
        }
        let first = PageID(UUID()), second = PageID(UUID())
        let landings = ScanSymbolCount.landings(
            rows: [row(1, page: 1, x: 10), row(2, page: 0, x: 20), row(3, page: 0, x: 30), row(4, page: 1, x: 40)],
            selected: [1, 2, 3],
            scores: [1: 0.8, 2: 0.93, 3: 0.71, 4: 0.99],
            pageIDs: [0: first, 1: second]
        )
        #expect(landings.count == 2)
        #expect(landings[0].pageID == first)
        #expect(landings[0].positions == [PDFPoint(x: 20, y: 50), PDFPoint(x: 30, y: 50)])
        #expect(landings[0].confidence == 0.71)
        // Row 4 was not ticked, so page 1 carries row 1 alone at 0.8.
        #expect(landings[1].positions == [PDFPoint(x: 10, y: 50)])
        #expect(landings[1].confidence == 0.8)
    }

    // MARK: - The whole flow over a scan

    /// A door symbol: a leaf and its quarter-circle swing in a 24 pt box at `origin`, the shape
    /// the raster benchmark counts.
    private static func door(_ context: CGContext, at origin: CGPoint, turns: Int, mirrored: Bool) {
        context.saveGState()
        context.translateBy(x: origin.x + 12, y: origin.y + 12)
        context.rotate(by: -CGFloat(turns) * .pi / 2)
        if mirrored { context.scaleBy(x: -1, y: 1) }
        context.translateBy(x: -12, y: -12)
        context.setStrokeColor(gray: 0, alpha: 1)
        context.setLineWidth(0.8)
        context.move(to: CGPoint(x: 2, y: 2)); context.addLine(to: CGPoint(x: 2, y: 22))
        context.move(to: CGPoint(x: 2, y: 22)); context.addArc(center: CGPoint(x: 2, y: 2), radius: 20, startAngle: .pi / 2, endAngle: 0, clockwise: true)
        context.move(to: CGPoint(x: 2, y: 2)); context.addLine(to: CGPoint(x: 22, y: 2))
        context.strokePath()
        context.restoreGState()
    }

    /// The door origins on the scan: upright, a quarter turn, a half turn, and mirrored.
    private static let doors: [(origin: CGPoint, turns: Int, mirrored: Bool)] = [
        (CGPoint(x: 100, y: 600), 0, false),
        (CGPoint(x: 300, y: 600), 1, false),
        (CGPoint(x: 100, y: 300), 2, false),
        (CGPoint(x: 300, y: 300), 0, true)
    ]

    /// A 595 × 842 pt sheet whose only content is a 150 dpi picture: four doors, a room outline
    /// and a bar of lettering — no vector linework at all.
    private static func scannedDoorsPDF() throws -> URL {
        let scale = 150.0 / 72
        let width = Int(595 * scale), height = Int(842 * scale)
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                             space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        for door in doors { Self.door(context, at: door.origin, turns: door.turns, mirrored: door.mirrored) }
        context.setStrokeColor(gray: 0, alpha: 1)
        context.setLineWidth(1)
        context.stroke(CGRect(x: 60, y: 200, width: 420, height: 500))
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 200, y: 450, width: 40, height: 3))
        let image = try #require(context.makeImage())
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("scan-symbols-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("ScannedDoors.pdf")
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let pdf = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        pdf.beginPDFPage(nil)
        pdf.draw(image, in: box)
        pdf.endPDFPage()
        pdf.closePDF()
        return url
    }

    /// Old output: the status note "This page has no vector geometry to match symbols in." and
    /// nothing counted.
    @Test("Box one door on a scan, name it D-12: every door is counted, stamped as read from the scan")
    func scannedSheetCountsFromThePicture() async throws {
        let window = try await R2AutomationAppTests.open(try Self.scannedDoorsPDF())
        defer { window.tearDown() }
        let previousPrompt = ProjectWindowController.symbolSearchPrompt
        let previousPresenter = ProjectWindowController.symbolReviewPresenter
        defer {
            ProjectWindowController.symbolSearchPrompt = previousPrompt
            ProjectWindowController.symbolReviewPresenter = previousPresenter
        }
        ProjectWindowController.symbolSearchPrompt = { _, _ in SymbolSearchRequest(designation: "D-12", scope: .thisPage) }
        var reviewed: SymbolCountReviewModel?
        ProjectWindowController.symbolReviewPresenter = { model, _ in
            reviewed = model
            Task { @MainActor in
                while model.isSearching { try? await Task.sleep(for: .milliseconds(20)) }
                model.accept()
            }
            return {}
        }

        window.controller.beginSymbolSchedule(for: window.document)
        // The person boxes the first door with a little paper around it.
        let first = Self.doors[0].origin
        window.canvas.onSnippetRegion?(PDFRectValue(x: first.x - 3, y: first.y - 3, width: 30, height: 30))

        var counted: MarkupRecord?
        for _ in 0..<600 {
            if let match = await window.core.session.orderedMarkups.first(where: { $0.subject == "D-12" }) { counted = match; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let markup = try #require(counted, "the scan schedule never landed a count markup")
        #expect(markup.tool == .count)
        let points = markup.geometry?.countPoints.map(\.position) ?? []
        // Four doors in four orientations; the room outline and the lettering are not doors.
        #expect(points.count == 4, "\(points)")
        // Each lands on its door's ink centre: the leaf and swing span (2, 2)–(22, 22) of the
        // 24 pt box, so the centre is the box's (12, 12) — 1 pt covers the half-pixel steps of
        // a 150 dpi picture.
        for door in Self.doors {
            let centre = CGPoint(x: door.origin.x + 12, y: door.origin.y + 12)
            #expect(points.contains { hypot($0.x - centre.x, $0.y - centre.y) < 1.5 }, "no count at \(centre)")
        }
        let capture = markup.measurement?.provenance?.capture
        #expect(capture?.kind == .fromScan)
        let confidence = try #require(capture?.confidence)
        #expect(confidence >= ScanSymbolCount.matchThreshold && confidence <= 1)
        // Every row said where it came from, and the boxed door was the example.
        let model = try #require(reviewed)
        #expect(model.rows.allSatisfy { $0.detail.hasPrefix("from the scan") })
        #expect(model.rows.filter(\.isExemplar).count == 1)
        // The note is posted after the batch lands, `settle()` and `refresh()`, so the markup can be
        // in the session before it: wait for the note rather than read it at once (sweep 10, I-25).
        var note: String?
        for _ in 0..<200 {
            note = window.core.status.snapshot.activeToolNote
            if note?.contains("counted from the scan") == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(note?.contains("counted from the scan") == true, "\(note ?? "no note")")
    }
}
