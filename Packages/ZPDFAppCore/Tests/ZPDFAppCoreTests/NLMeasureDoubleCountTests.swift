import Foundation
import Testing
import ZPDFContracts
import ZPDFUIPresentation
@testable import ZPDFAppCore

/// NL-MEASURE-13: two areas of the same subject that overlap are named in the tray; different
/// subjects, cutouts and areas that only touch raise nothing. Hand-derived at 1 m/pt.
@Suite("Double-count guard in the tray (NL-MEASURE-13)")
@MainActor
struct NLMeasureDoubleCountTests {

    static func rect(_ page: PageID, _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> MeasurementGeometry {
        MeasurementGeometry(pageID: page, polygons: [PolygonGeometry(outer: PolygonRing(points: [
            PDFPoint(x: x, y: y), PDFPoint(x: x + w, y: y), PDFPoint(x: x + w, y: y + h), PDFPoint(x: x, y: y + h)
        ], isClosed: true))])
    }

    static func area(_ documentID: DocumentID, _ page: PageID, subject: String, label: String, _ geometry: MeasurementGeometry) -> ZPDFContracts.MarkupRecord {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        return ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: documentID, pageID: page, kind: .measurement, tool: .area,
            subject: subject, label: label, author: "t", geometry: geometry, createdAt: stamp, modifiedAt: stamp
        )
    }

    private func environment() async throws -> (AppCoreEnvironment, DocumentID, PageID) {
        let documentID = DocumentID(UUID())
        let page = ZPDFContracts.PageDescriptor(
            id: PageID(UUID()), documentID: documentID, index: 0, label: "A-101",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 1_000, height: 1_000))
        )
        let session = try TakeoffSession(documentID: documentID, pages: [page])
        _ = try await session.calibrate(
            page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 100, knownLengthUnit: .metre
        )
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        return (environment, documentID, page.id)
    }

    private func doubleCounts(_ environment: AppCoreEnvironment) -> [AppWarning] {
        environment.document.warnings.filter { $0.source == AppCoreEnvironment.doubleCountWarningSource }
    }

    /// A = [0,10]², B = [9.6,19.6]×[0,1]: they share 0.4 × 1 = 0.40 m².
    /// Old output: no warning at all; both areas summed into Floor finish.
    @Test("Two overlapping “Floor finish” areas raise one warning naming both and 0.40 m²")
    func overlappingSameSubject() async throws {
        let (environment, documentID, page) = try await environment()
        let a = Self.area(documentID, page, subject: "Floor finish", label: "Area A", Self.rect(page, 0, 0, 10, 10))
        let b = Self.area(documentID, page, subject: "Floor finish", label: "Area B", Self.rect(page, 9.6, 0, 10, 1))
        try await environment.commands.perform(.addMarkup(a))
        try await environment.commands.perform(.addMarkup(b))
        await environment.refreshDoubleCountWarnings(enabled: true)
        let warnings = doubleCounts(environment)
        #expect(warnings.count == 1)
        let warning = try #require(warnings.first)
        #expect(warning.title.contains("Floor finish"))
        #expect(warning.message.contains("Area A") && warning.message.contains("Area B"))
        #expect(warning.message.contains("0.40"))
        #expect(warning.relatedMarkupID == b.id.rawValue)

        // Moving B clear of A takes the warning down.
        try await environment.commands.perform(.moveMarkup(id: b.id, dx: 5, dy: 0))
        await environment.refreshDoubleCountWarnings(enabled: true)
        #expect(doubleCounts(environment).isEmpty)
    }

    @Test("Different subjects, touching edges and a turned-off guard raise nothing")
    func nothingToSay() async throws {
        let (environment, documentID, page) = try await environment()
        try await environment.commands.perform(.addMarkup(Self.area(documentID, page, subject: "Floor finish", label: "A", Self.rect(page, 0, 0, 10, 10))))
        try await environment.commands.perform(.addMarkup(Self.area(documentID, page, subject: "Screed", label: "B", Self.rect(page, 5, 0, 10, 10))))
        try await environment.commands.perform(.addMarkup(Self.area(documentID, page, subject: "Floor finish", label: "C", Self.rect(page, 10, 0, 10, 10))))
        await environment.refreshDoubleCountWarnings(enabled: true)
        #expect(doubleCounts(environment).isEmpty)

        try await environment.commands.perform(.addMarkup(Self.area(documentID, page, subject: "Floor finish", label: "D", Self.rect(page, 2, 2, 2, 2))))
        await environment.refreshDoubleCountWarnings(enabled: false)
        #expect(doubleCounts(environment).isEmpty, "the guard is off")
        await environment.refreshDoubleCountWarnings(enabled: true)
        #expect(doubleCounts(environment).count == 1, "A and D overlap by 4 m²")
    }

    /// A cutout inside its parent is part of it, never a second area.
    @Test("A cutout and its parent are never a double count")
    func cutoutIsNotADoubleCount() async throws {
        let (environment, documentID, page) = try await environment()
        let parent = Self.area(documentID, page, subject: "Slab", label: "Slab A", Self.rect(page, 0, 0, 10, 10))
        try await environment.commands.perform(.addMarkup(parent))
        var hole = Self.area(documentID, page, subject: "Slab", label: "Hole", Self.rect(page, 2, 2, 2, 2))
        hole.kind = .polygon
        hole.tool = .polygonCutout
        try await environment.commands.perform(.addCutout(parent: parent.id, cutout: hole))
        await environment.refreshDoubleCountWarnings(enabled: true)
        #expect(doubleCounts(environment).isEmpty)
    }

    /// The canvas hatch's region: A = [0,10]², B = [9.6,19.6]×[0,1] share [9.6,10]×[0,1]; turning
    /// the guard off clears it, and the canvas is told both times.
    @Test("The overlap region is published for the canvas hatch, and cleared when the guard is off")
    func regionsForTheHatch() async throws {
        let (environment, documentID, page) = try await environment()
        var told = 0
        environment.onDoubleCountRegionsChanged = { told += 1 }
        try await environment.commands.perform(.addMarkup(Self.area(documentID, page, subject: "Floor finish", label: "A", Self.rect(page, 0, 0, 10, 10))))
        try await environment.commands.perform(.addMarkup(Self.area(documentID, page, subject: "Floor finish", label: "B", Self.rect(page, 9.6, 0, 10, 1))))
        await environment.refreshDoubleCountWarnings(enabled: true)
        let region = try #require(environment.doubleCountRegions[page])
        #expect(region.count == 1)
        let xs = region[0].outer.uniquePoints.map(\.x), ys = region[0].outer.uniquePoints.map(\.y)
        #expect(Swift.abs((xs.min() ?? 0) - 9.6) < 1e-9 && Swift.abs((xs.max() ?? 0) - 10) < 1e-9)
        #expect(Swift.abs(ys.min() ?? 1) < 1e-9 && Swift.abs((ys.max() ?? 0) - 1) < 1e-9)
        #expect(told >= 1)
        let before = told
        await environment.refreshDoubleCountWarnings(enabled: false)
        #expect(environment.doubleCountRegions.isEmpty)
        #expect(told == before + 1)
    }
}
