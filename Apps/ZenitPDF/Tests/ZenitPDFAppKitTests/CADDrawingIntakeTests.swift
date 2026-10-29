import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
@testable import ZenitPDFAppKit

/// NL-PLAT-05 in the app: a DXF opens as a sheet at the file's own scale, and a 12 000 mm wall
/// measures 12.000 m with no calibration. A DWG gets a sentence. Nothing is put on screen.
@MainActor
@Suite("CAD drawings in the app — NL-PLAT-05", .appTierSerialised)
struct CADDrawingIntakeTests {

    private static func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zpdf-cad-app-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static let wallDXF = """
    0\nSECTION\n2\nHEADER\n9\n$INSUNITS\n70\n4\n0\nENDSEC\n0\nSECTION\n2\nTABLES\n0\nTABLE\n2\nLAYER\n70\n2\n\
    0\nLAYER\n2\nA-WALL\n70\n0\n0\nLAYER\n2\nA-DOOR\n70\n0\n0\nENDTAB\n0\nENDSEC\n0\nSECTION\n2\nENTITIES\n\
    0\nLINE\n8\nA-WALL\n10\n0\n20\n0\n11\n12000\n21\n0\n0\nLINE\n8\nA-DOOR\n10\n0\n20\n3000\n11\n900\n21\n3000\n0\nENDSEC\n0\nEOF\n
    """

    @Test("Opening a DXF gives a sheet whose page carries the file's scale: the 12 000 mm wall measures 12.000 m")
    func dxfOpensAtItsOwnScale() async throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let dxf = root.appendingPathComponent("Plan A-101.dxf")
        try Data(Self.wallDXF.utf8).write(to: dxf)
        #expect(CADDrawingIntake.canOpen(dxf))

        let controller = ZenitDocumentController()
        ZenitDocumentController.derivedDrawingOpener = { url, _, completion in
            do { completion(try AppTestSupport.makeDocument(opening: url), false, nil) } catch { completion(nil, false, error) }
        }
        defer { ZenitDocumentController.derivedDrawingOpener = nil }
        var opened: NSDocument?, failure: (any Error)?, finished = false
        controller.openCADDrawing(dxf, release: nil, display: false, root: root.appendingPathComponent("derived")) { document, _, error in
            opened = document; failure = error; finished = true
        }
        #expect(await AppTestSupport.wait(upTo: 30) { finished })
        #expect(failure == nil, "\(String(describing: failure))")
        let document = try #require(opened as? ZenitPDFProjectDocument)
        defer { document.close() }
        #expect(await AppTestSupport.wait { document.core != nil })
        let core = try #require(document.core)
        #expect(await AppTestSupport.wait { core.document.warnings.contains { $0.id == CADDrawingIntake.noteID } })
        let page = try #require(await core.session.firstPageID)
        let scale = try #require(await core.session.scale(onPage: page))
        #expect(scale.source == .preset)
        #expect(scale.label?.contains("from the drawing file") == true, "\(String(describing: scale.label))")

        // Measure the wall where the sheet drew it: extents 12 000 × 3 000 mm, 1:20, 10 mm margin.
        let y = 10.0 / 25.4 * 72
        let record = MarkupRecord(
            id: MarkupID(UUID()), documentID: try #require(document.drawing?.documentID), pageID: page,
            kind: .measurement, tool: .length,
            geometry: MeasurementGeometry(pageID: page, points: [PDFPoint(x: 10.0 / 25.4 * 72, y: y), PDFPoint(x: 610.0 / 25.4 * 72, y: y)]),
            createdAt: Date(), modifiedAt: Date())
        _ = try await core.commands.perform(.addMarkup(record))
        let measured = try #require(await core.session.markup(record.id)?.measurement)
        let metres = try #require(measured.values[.planLength]?.value)
        #expect(abs(NSDecimalNumber(decimal: metres).doubleValue - 12.0) < 1e-9, "measured \(metres) m")
    }

    @Test("A binary DXF refused by the geometry service reaches the person in the reader's own words")
    func serviceRefusalKeepsItsWords() async throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let dxf = root.appendingPathComponent("Binary.dxf")
        try (Data("AutoCAD Binary DXF\r\n".utf8) + Data(repeating: 0, count: 32)).write(to: dxf)
        let controller = ZenitDocumentController()
        var failure: NSError?, finished = false
        controller.openCADDrawing(dxf, release: nil, display: false, root: root.appendingPathComponent("derived")) { _, _, error in
            failure = error as NSError?; finished = true
        }
        #expect(await AppTestSupport.wait(upTo: 30) { finished })
        let error = try #require(failure)
        #expect(error.localizedDescription == "Zenit PDF cannot open “Binary.dxf” as a drawing.")
        #expect(error.localizedRecoverySuggestion?.contains("binary DXF") == true, "\(String(describing: error.localizedRecoverySuggestion))")
    }

    @Test("A DWG is answered with the way forward, not 'cannot open'")
    func dwgGetsASentence() async throws {
        let controller = ZenitDocumentController()
        var failure: NSError?
        controller.openCADDrawing(URL(fileURLWithPath: "/tmp/plan.dwg"), release: nil, display: false) { _, _, error in
            failure = error as NSError?
        }
        let error = try #require(failure)
        #expect(error.localizedDescription == "“plan.dwg” is a DWG drawing.")
        #expect(error.localizedRecoverySuggestion?.contains("save it as DXF") == true)
    }
}
