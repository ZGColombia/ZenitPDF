import AppKit
import CoreGraphics
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFRasterAnalysis
import ZPDFUIPresentation
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// Round 2, platform unit: the automation items in the app — NL-AUTO-03/14/16/18/20/21. Every
/// review is answered by injection; hand-derived quantities throughout.
@MainActor
@Suite("r2-platform automation app tier", .appTierSerialised)
struct R2AutomationAppTests {

    struct Window {
        let document: ZenitPDFProjectDocument
        let controller: ProjectWindowController
        let canvas: PDFCanvasViewController
        let core: AppCoreEnvironment
        let shell: ProjectShellEnvironment

        @MainActor
        func tearDown() {
            document.close()
            try? FileManager.default.removeItem(at: document.fileURL?.deletingLastPathComponent() ?? URL(fileURLWithPath: "/nonexistent"))
        }
    }

    /// A drawing in a real window controller, calibrated `pointsPerMetre` page points = 1 m on
    /// every page when `calibrate` is set.
    static func open(_ url: URL, pointsPerMetre: Double = 100, calibrate: Bool = true) async throws -> Window {
        let document = try AppTestSupport.makeDocument(opening: url)
        #expect(await AppTestSupport.wait { document.core != nil && document.drawing != nil && document.shell != nil })
        let core = try #require(document.core)
        let shell = try #require(document.shell)
        let controller = ProjectWindowController(document: document)
        document.addWindowController(controller)
        #expect(await AppTestSupport.wait { controller.canvasController(for: document) != nil })
        let canvas = try #require(controller.canvasController(for: document))
        if calibrate {
            for page in try #require(document.drawing).pages {
                _ = try await core.commands.calibrate(page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: pointsPerMetre, y: 0),
                                                      knownLength: 1, knownLengthUnit: .metre)
            }
            await core.refresh()
        }
        return Window(document: document, controller: controller, canvas: canvas, core: core, shell: shell)
    }

    static func markups(_ core: AppCoreEnvironment, atLeast count: Int) async -> [MarkupRecord] {
        var records = await core.session.orderedMarkups
        for _ in 0..<150 where records.count < count {
            try? await Task.sleep(for: .milliseconds(20))
            records = await core.session.orderedMarkups
        }
        return records
    }

    static func metres(_ value: Decimal?) -> Double { value.map { NSDecimalNumber(decimal: $0).doubleValue } ?? -1 }

    /// The wall plan of `WallCentrelineTests`, at 100 pt = 1 m, offset (50, 50) on the page.
    static let wallPlan: String = {
        func l(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> String { "\(x0 + 50) \(y0 + 50) m \(x1 + 50) \(y1 + 50) l S" }
        return (["0.5 w 0 0 0 RG"] + [
            l(0, 0, 1000, 0), l(1000, 0, 1000, 600), l(1000, 600, 0, 600), l(0, 600, 0, 0),
            l(25, 25, 492.5, 25), l(507.5, 25, 975, 25), l(975, 25, 975, 575), l(975, 575, 507.5, 575), l(492.5, 575, 25, 575), l(25, 575, 25, 25),
            l(492.5, 25, 492.5, 250), l(492.5, 340, 492.5, 575), l(507.5, 25, 507.5, 250), l(507.5, 340, 507.5, 575),
        ]).joined(separator: "\n")
    }()

    // MARK: - NL-AUTO-20

    @Test("Find Walls proposes 31.00 m of 250 mm wall and 4.60 m of 150 mm wall with the door left out, and adds only the ticked class")
    func findWalls() async throws {
        let url = try AutomationFixtures.writeSinglePage(named: "Walls.pdf", mediaBox: "0 0 1100 700", content: Self.wallPlan)
        let window = try await Self.open(url)
        defer { window.tearDown() }
        let previous = ProjectWindowController.wallReviewDecision
        defer { ProjectWindowController.wallReviewDecision = previous }
        var shown: [ProjectWindowController.WallProposal] = []
        ProjectWindowController.wallReviewDecision = { proposals, _ in
            shown = proposals
            return Set(proposals.indices.filter { proposals[$0].thicknessMillimetres == 150 })
        }
        let added = await window.controller.runWallTakeoff(for: window.document)
        #expect(shown.map(\.thicknessMillimetres) == [150, 250])
        let outer = try #require(shown.first { $0.thicknessMillimetres == 250 })
        let partition = try #require(shown.first { $0.thicknessMillimetres == 150 })
        #expect(abs(outer.lengthMetres - 31.00) / 31.00 < 0.005, "\(outer.lengthMetres)")
        #expect(abs(partition.lengthMetres - 4.60) / 4.60 < 0.005, "\(partition.lengthMetres)")
        #expect(partition.openingWidthsMetres.count == 1 && abs(partition.openingWidthsMetres[0] - 0.90) < 1e-6)
        #expect(added == 2, "only the ticked class: the partition's two runs")
        let records = await Self.markups(window.core, atLeast: 2)
        #expect(records.allSatisfy { $0.subject == "Wall 150 mm" && $0.tool == .polylength })
        let total = records.reduce(0.0) { $0 + Self.metres($1.measurement?.values[.planLength]?.value) }
        #expect(abs(total - 4.60) < 1e-9, "the session measures the committed centrelines: \(total)")
        #expect(records.allSatisfy { $0.measurement?.provenance?.capture.kind == .wallCentreline && $0.measurement?.provenance?.capture.wallThicknessMetres == Decimal(string: "0.15") })
    }

    @Test("Find Walls refuses an uncalibrated sheet and says why")
    func findWallsNeedsAScale() async throws {
        let url = try AutomationFixtures.writeSinglePage(named: "Walls raw.pdf", mediaBox: "0 0 1100 700", content: Self.wallPlan)
        let window = try await Self.open(url, calibrate: false)
        defer { window.tearDown() }
        #expect(await window.controller.runWallTakeoff(for: window.document) == 0)
        #expect(window.core.status.snapshot.activeToolNote?.hasPrefix("Calibrate this sheet first") == true)
    }

    // MARK: - NL-AUTO-21: repeated sheets

    @Test("Sheets 1 and 3 drawn alike are found; applying ×2 puts Repeat × 2 on sheet 1's measurements, in one undo")
    func repeatedSheets() async throws {
        let plan = "0.5 w 0 0 0 RG 100 100 m 900 100 l 900 600 l 100 600 l h S 500 100 m 500 600 l S"
        let other = "0.5 w 0 0 0 RG 100 100 m 900 100 l 900 600 l 100 600 l h S 300 100 m 300 600 l S 100 350 m 300 350 l S"
        let url = try AutomationFixtures.writePages(named: "Storeys.pdf", mediaBox: "0 0 1000 700", contents: [plan, other, plan])
        let window = try await Self.open(url)
        defer { window.tearDown() }
        let page = try #require(window.document.drawing?.pages.first)
        _ = try await window.core.commands.perform(.addMarkup(MarkupRecord(
            id: MarkupID(UUID()), documentID: await window.core.session.documentID, pageID: page.id, kind: .measurement, tool: .area,
            subject: "Floor", geometry: MeasurementGeometry(pageID: page.id, polygons: [PolygonGeometry(outer: PolygonRing(points: [
                PDFPoint(x: 100, y: 100), PDFPoint(x: 500, y: 100), PDFPoint(x: 500, y: 600), PDFPoint(x: 100, y: 600)], isClosed: true))]),
            createdAt: Date(), modifiedAt: Date())))
        await window.core.commands.settle()
        let previous = ProjectWindowController.repeatedSheetsDecision
        defer { ProjectWindowController.repeatedSheetsDecision = previous }
        var asked: [ProjectWindowController.RepeatedSheetGroup] = []
        ProjectWindowController.repeatedSheetsDecision = { prompt, _ in asked.append(prompt.group); #expect(prompt.measurementCount == 1); return true }
        let groups = await window.controller.runRepeatedSheets(for: window.document)
        let pages = try #require(window.document.drawing?.pages)
        #expect(groups.map(\.pageIDs) == [[pages[0].id, pages[2].id]])
        #expect(asked.first?.multiplier == 2)
        let floor = try #require(await Self.markups(window.core, atLeast: 1).first)
        #expect(RepetitionColumn.count(of: floor) == 2)
        // 4 × 5 m = 20 m² counted twice: the ledger's repeated total is 40 m².
        #expect(RepetitionColumn.repeatedTotal(value: try #require(floor.measurement?.values[.planArea]?.value), count: 2) == 40)
        window.document.undoManager?.undo()
        await window.core.commands.settle()
        #expect(RepetitionColumn.count(of: try #require(await window.core.session.orderedMarkups.first)) == 1)
    }

    // MARK: - NL-AUTO-16: the Takeoff Assistant

    @Test("Prepare This Set files a sheet name, a scale and two rooms; accepting a room adds an area marked as detected")
    func takeoffAssistant() async throws {
        let content = """
        0.5 w 0 0 0 RG 100 200 m 500 200 l 500 350 l 100 350 l h S 300 200 m 300 350 l S
        BT /F1 8 Tf 700 60 Td (DRAWING NO.) Tj ET BT /F1 8 Tf 760 60 Td (A-101) Tj ET
        BT /F1 8 Tf 700 40 Td (TITLE) Tj ET BT /F1 8 Tf 740 40 Td (Ground floor) Tj ET
        BT /F1 8 Tf 700 20 Td (SCALE 1:50) Tj ET
        BT /F1 8 Tf 150 300 Td (KITCHEN) Tj ET BT /F1 8 Tf 350 300 Td (BEDROOM) Tj ET
        """
        let url = try AutomationFixtures.writeSinglePage(named: "Assistant.pdf", mediaBox: "0 0 842 595", content: content)
        let window = try await Self.open(url, calibrate: false)
        defer { window.tearDown() }
        let filed = await window.controller.runTakeoffAssistant(for: window.document)
        let inbox = window.document.automation.inbox
        #expect(filed == 4, "\(inbox.proposals.map(\.summary))")
        #expect(inbox.proposals.first { $0.kind == .sheetName }?.sheetNumber == "A-101")
        #expect(inbox.proposals.first { $0.kind == .scale }?.scaleDisplay == "1:50")
        #expect(await window.core.session.orderedMarkups.isEmpty, "nothing is committed by preparing")

        let kitchen = try #require(inbox.proposals.first { $0.kind == .room && $0.roomName == "KITCHEN" })
        #expect(await window.controller.acceptAssistantProposal(kitchen, document: window.document))
        let room = try #require(await Self.markups(window.core, atLeast: 1).first)
        #expect(room.subject == "KITCHEN")
        #expect(room.measurement?.provenance == nil || room.measurement?.provenance?.capture.kind == .roomDetected)
        #expect(inbox.proposals.first { $0.id == kitchen.id }?.state == .accepted)
        let scale = try #require(inbox.proposals.first { $0.kind == .scale })
        #expect(await window.controller.acceptAssistantProposal(scale, document: window.document))
        #expect(await window.core.session.scale(onPage: try #require(window.document.drawing?.pages.first).id) != nil)
        // Once calibrated, the room was measured: 200 × 150 pt at 1:50 is 3.528 m × 2.646 m.
        await window.core.commands.settle()
        let measured = try #require(await window.core.session.orderedMarkups.first)
        #expect(measured.measurement?.provenance?.capture.kind == .roomDetected)
        let name = try #require(inbox.proposals.first { $0.kind == .sheetName })
        #expect(await window.controller.acceptAssistantProposal(name, document: window.document))
        #expect(await window.core.session.sheetIdentity(of: try #require(window.document.drawing?.pages.first).id)?.number == "A-101")
    }

    @Test("Accepting a library-symbol proposal lands one count of every hit, marked as matched")
    func assistantSymbolHits() async throws {
        let window = try await Self.open(try AutomationFixtures.writeSinglePage(named: "Symbols.pdf", content: "0.5 w 0 0 0 RG 72 72 m 100 100 l S"))
        defer { window.tearDown() }
        let page = try #require(window.document.drawing?.pages.first)
        let proposal = AssistantProposal(pageID: page.id.rawValue, pageIndex: 0, kind: .symbols, confidence: 0.9,
                                         symbolDesignation: "Floor drain",
                                         symbolPositions: [PDFPoint(x: 604, y: 104), PDFPoint(x: 704, y: 104)])
        #expect(await window.controller.acceptAssistantProposal(proposal, document: window.document))
        let count = try #require(await Self.markups(window.core, atLeast: 1).first)
        #expect(count.tool == .count && count.subject == "Floor drain")
        #expect(count.geometry?.countPoints.count == 2)
        #expect(count.measurement?.values[.count]?.value == 2)
        #expect(count.measurement?.provenance?.capture.kind == .symbolMatched)
    }

    // MARK: - NL-AUTO-18: auto-trace records how it captured

    @Test("An auto-traced room records it was traced, and says so in the derivation")
    func autoTraceCapture() async throws {
        let content = "1 w 0 0 0 RG 72 72 m 372 72 l 372 272 l 72 272 l h S"
        let window = try await Self.open(try AutomationFixtures.writeSinglePage(named: "Traced.pdf", content: content))
        defer { window.tearDown() }
        window.shell.perform(.measureArea)
        window.canvas.handleClick(at: PDFPointValue(x: 100, y: 100), additive: false, optionHeld: true)
        await window.canvas.settleAutoTrace()
        let record = try #require(await Self.markups(window.core, atLeast: 1).first)
        #expect(record.measurement?.provenance?.capture.kind == .autoTraced)
        // 300 × 200 pt at 100 pt/m = 6 m², computed by the session, not the stamp.
        #expect(abs(Self.metres(record.measurement?.values[.planArea]?.value) - 6) < 1e-9)
    }

    // MARK: - NL-AUTO-14: auto-trace on a scanned sheet

    /// A sheet whose only content is a picture of a room: 300 × 200 pt with 1 pt walls, drawn at
    /// 150 dpi — a scan, with no vector linework at all.
    static func scannedRoomPDF() throws -> URL {
        let scale = 150.0 / 72
        let width = Int(595 * scale), height = Int(842 * scale)
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                             space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.setStrokeColor(gray: 0, alpha: 1)
        context.setLineWidth(1)
        context.stroke(CGRect(x: 72, y: 72, width: 300, height: 200))
        let image = try #require(context.makeImage())
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("r2-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Scan.pdf")
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let pdf = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        pdf.beginPDFPage(nil)
        pdf.draw(image, in: box)
        pdf.endPDFPage()
        pdf.closePDF()
        return url
    }

    @Test("⌥-click in a room on a scanned sheet traces it from the pixels within 1 % and marks it from the scan")
    func scanTrace() async throws {
        let window = try await Self.open(try Self.scannedRoomPDF())
        defer { window.tearDown() }
        window.shell.perform(.measureArea)
        window.canvas.handleClick(at: PDFPointValue(x: 200, y: 150), additive: false, optionHeld: true)
        await window.canvas.settleAutoTrace()
        let record = try #require(await Self.markups(window.core, atLeast: 1).first)
        #expect(record.measurement?.provenance?.capture.kind == .fromScan)
        // A thin stroke is traced along its middle, as the vector trace does: the walls' centreline
        // ring is 300 × 200 pt = 60 000 pt² = 6.00 m² at 100 pt/m. One scan pixel is 0.48 pt, so
        // the band middles may sit up to half a pixel off — 1 % covers that, and no more.
        let area = Self.metres(record.measurement?.values[.planArea]?.value)
        #expect(abs(area - 6.00) / 6.00 < 0.01, "\(area) m²")
        #expect(window.core.status.snapshot.activeToolNote?.hasPrefix("Traced from the scan") == true)
    }

    // MARK: - NL-AUTO-03: text from the best source

    @Test("A region with no text layer is read by region recognition for a command that asks, never for one that does not")
    func pageTextSources() async throws {
        let window = try await Self.open(try AutomationFixtures.writeSinglePage(named: "Blank.pdf", content: "0.5 w 0 0 0 RG 72 72 m 100 100 l S"))
        defer { window.tearDown() }
        let previous = PageTextLoader.regionRecognizer
        defer { PageTextLoader.regionRecognizer = previous }
        PageTextLoader.regionRecognizer = { _, _, region in
            [SourcedTextLine(text: "D-12  900 × 2100", boundsInPageSpace: PDFRectValue(x: region.minX + 2, y: region.minY + 2, width: 60, height: 8),
                             confidence: 0.83, source: .regionOCR)]
        }
        let page = try #require(window.document.drawing?.pages.first)
        let region = PDFRectValue(x: 50, y: 50, width: 200, height: 100)
        let asked = await PageTextLoader.lines(document: window.document, page: page, region: region, allowRegionOCR: true)
        #expect(asked.map(\.source) == [.regionOCR])
        #expect(asked.first?.confidence == 0.83)
        let notAsked = await PageTextLoader.lines(document: window.document, page: page, region: region, allowRegionOCR: false)
        #expect(notAsked.isEmpty)
    }
}
