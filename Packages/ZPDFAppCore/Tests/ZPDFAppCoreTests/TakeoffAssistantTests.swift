import CoreGraphics
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFPersistence
import ZPDFSnapEngine
import ZPDFUIPresentation
import ZPDFVectorExtraction

/// NL-AUTO-16: "Prepare this set" files proposals per sheet — a name, a scale, the rooms — in an
/// inbox kept in the project. Nothing is committed; a rerun does not offer again what a person
/// decided; the inbox survives a reopen.
@Suite("Takeoff Assistant inbox", .serialized)
struct TakeoffAssistantTests {

    static func line(_ id: UInt64, _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> VectorPrimitive {
        VectorPrimitive(id: id, parentID: nil, kind: .lineSegment, geometry: .line(VectorLine(start: CGPoint(x: x0, y: y0), end: CGPoint(x: x1, y: y1))),
                        bounds: VectorBounds(minX: min(x0, x1), minY: min(y0, y1), maxX: max(x0, x1), maxY: max(y0, y1)),
                        sourceObjectID: id, subpathIndex: 0, nestingDepth: 0, paint: .stroked, strokeWidth: 0.5,
                        strokeIsDashed: false, clipRelation: .unclipped, clipBounds: nil, confidence: 1, layerID: nil)
    }

    /// A sheet 842 × 595 with a title block reading "DRAWING NO. A-101" / "TITLE Ground floor",
    /// the notation "SCALE 1:50", and two rooms side by side (200 × 150 pt each) labelled.
    static func input(pageID: UUID = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!, named: Bool = false, scaled: Bool = false) -> AssistantPageInput {
        func text(_ t: String, _ x: Double, _ y: Double) -> RecognisedTextLine {
            RecognisedTextLine(text: t, boundsInPageSpace: PDFRectValue(x: x, y: y, width: Double(t.count) * 5, height: 8))
        }
        let lines = [text("DRAWING NO.", 700, 60), text("A-101", 760, 60), text("TITLE", 700, 40), text("Ground floor", 740, 40),
                     text("SCALE 1:50", 700, 20), text("KITCHEN", 150, 300), text("BEDROOM", 350, 300)]
        let walls = [line(1, 100, 200, 500, 200), line(2, 500, 200, 500, 350), line(3, 500, 350, 100, 350), line(4, 100, 350, 100, 200),
                     line(5, 300, 200, 300, 350)]
        return AssistantPageInput(pageID: pageID, pageIndex: 0, pageBox: PDFRectValue(x: 0, y: 0, width: 842, height: 595),
                                  lines: lines, primitives: walls, metresPerPoint: nil, isNamed: named, hasScale: scaled)
    }

    static let roomOptions = RoomDetector.Options(minimumArea: 2_000, maximumArea: 1_000_000, minimumWidth: 20, maximumClosureWidth: 30)

    @Test("One sheet yields its name, its scale and its two rooms — as open proposals, nothing committed")
    func proposals() {
        let found = TakeoffAssistant.proposals(for: Self.input(), roomOptions: Self.roomOptions)
        let name = found.first { $0.kind == .sheetName }
        #expect(name?.sheetNumber == "A-101")
        #expect(name?.sheetTitle == "Ground floor")
        let scale = found.first { $0.kind == .scale }
        #expect(scale?.scaleDisplay == "1:50")
        let rooms = found.filter { $0.kind == .room }
        #expect(rooms.count == 2)
        #expect(Set(rooms.compactMap(\.roomName)) == ["KITCHEN", "BEDROOM"])
        #expect(found.allSatisfy { $0.state == .open })
        // A named, scaled sheet is only searched for rooms.
        #expect(TakeoffAssistant.proposals(for: Self.input(named: true, scaled: true), roomOptions: Self.roomOptions).allSatisfy { $0.kind == .room })
    }

    @Test("A library symbol drawn twice on the sheet is one proposal of two hits, marked with the symbol's name")
    func librarySymbolHits() throws {
        // A cross 8 × 8 pt drawn at (600, 100) and at (700, 100), apart from the rooms.
        func cross(_ id: UInt64, _ x: Double, _ y: Double) -> [VectorPrimitive] {
            [Self.line(id, x, y, x + 8, y + 8), Self.line(id + 1, x, y + 8, x + 8, y)]
        }
        let symbols = cross(100, 600, 100) + cross(110, 700, 100)
        let exemplar = try SymbolExemplar(primitives: symbols, region: VectorBounds(minX: 599, minY: 99, maxX: 609, maxY: 109))
        let entry = SymbolLibraryEntry(designation: "Floor drain", exemplar: exemplar, savedAt: Date(timeIntervalSince1970: 1_790_000_000))
        let base = Self.input(named: true, scaled: true)
        let page = AssistantPageInput(pageID: base.pageID, pageIndex: 0, pageBox: base.pageBox, lines: base.lines,
                                      primitives: (base.primitives ?? []) + symbols, metresPerPoint: nil, isNamed: true, hasScale: true)
        let found = TakeoffAssistant.proposals(for: page, roomOptions: Self.roomOptions, library: [entry])
        let hits = try #require(found.first { $0.kind == .symbols })
        #expect(hits.symbolDesignation == "Floor drain")
        #expect(hits.symbolPositions?.count == 2)
        #expect(hits.summary == "Count 2 × “Floor drain” (library symbol)")
        #expect(found.filter { $0.kind == .room }.count == 2, "the rooms are still found beside the symbols")
        // Without a library nothing symbol-shaped is proposed.
        #expect(TakeoffAssistant.proposals(for: page, roomOptions: Self.roomOptions).allSatisfy { $0.kind != .symbols })
    }

    @MainActor
    @Test("The inbox keeps decisions across a rerun and a reopen of the project")
    func inboxPersists() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("assistant-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pdf = try ZPDFTestingSupportShim.fixture(in: directory)
        let url = directory.appendingPathComponent("Assistant.zpdfproj", isDirectory: true)
        let package = try await ProjectPackage.create(at: url, displayName: "Assistant", originalPDF: pdf)

        let inbox = AutomationInbox()
        await inbox.attach(package: package)
        let page = Self.input().pageID
        let first = await inbox.file(TakeoffAssistant.proposals(for: Self.input(), roomOptions: Self.roomOptions), forPage: page)
        #expect(first.count == 4)
        #expect(inbox.openProposals.filter { $0.pageID == page }.count == 4)
        let rejected = try #require(first.first { $0.kind == .scale })
        await inbox.decide(rejected.id, .rejected)
        let accepted = try #require(first.first { $0.kind == .sheetName })
        await inbox.decide(accepted.id, .accepted)
        #expect(inbox.openProposals.filter { $0.pageID == page }.count == 2)

        // A rerun replaces the open proposals and does not offer the decided ones again.
        let rerun = await inbox.file(TakeoffAssistant.proposals(for: Self.input(), roomOptions: Self.roomOptions), forPage: page)
        #expect(rerun.count == 2, "only the two rooms are open again")
        #expect(inbox.proposals.count == 4)

        _ = try await package.save()
        try await package.close()
        guard case .opened(let reopened) = try await ProjectPackage.open(at: url) else {
            Issue.record("reopen required recovery")
            return
        }
        let again = AutomationInbox()
        await again.attach(package: reopened)
        #expect(again.proposals.count == 4)
        #expect(again.openProposals.filter { $0.pageID == page }.count == 2)
        #expect(again.proposals.first { $0.id == rejected.id }?.state == .rejected)
        #expect(again.proposals.first { $0.id == accepted.id }?.state == .accepted)
        try await reopened.close()
    }
}

/// A one-page PDF for a package, written here so the test needs no other fixture.
enum ZPDFTestingSupportShim {
    static func fixture(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("sheet.pdf")
        var box = CGRect(x: 0, y: 0, width: 842, height: 595)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { throw CocoaError(.fileWriteUnknown) }
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        return url
    }
}
