import Foundation
import Testing
@testable import ZPDFGeometryServiceCore
import ZPDFServiceClient
import ZPDFServiceWire

/// NL-PLAT-05, round 2: a DXF is parsed in the geometry service, not in the application. The
/// subprocess worker runs the same core the `.xpc` bundle runs, over the same wire; values are
/// hand-derived from the fixture's numbers.
@Suite("DXF through the geometry service (NL-PLAT-05)")
struct DXFThroughServiceTests {

    /// An ASCII DXF in millimetres: a 12 000 × 8 000 mm room on layer A-WALL, and a 900 mm line
    /// on A-DOOR.
    static let roomDXF: Data = {
        func line(_ layer: String, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> String {
            "0\nLINE\n8\n\(layer)\n10\n\(x1)\n20\n\(y1)\n30\n0\n11\n\(x2)\n21\n\(y2)\n31\n0\n"
        }
        var text = "0\nSECTION\n2\nHEADER\n9\n$INSUNITS\n70\n4\n0\nENDSEC\n"
        text += "0\nSECTION\n2\nTABLES\n0\nTABLE\n2\nLAYER\n70\n2\n"
        for layer in ["A-WALL", "A-DOOR"] { text += "0\nLAYER\n2\n\(layer)\n70\n0\n62\n7\n6\nCONTINUOUS\n" }
        text += "0\nENDTAB\n0\nENDSEC\n0\nSECTION\n2\nBLOCKS\n0\nENDSEC\n0\nSECTION\n2\nENTITIES\n"
        text += line("A-WALL", 0, 0, 12_000, 0) + line("A-WALL", 12_000, 0, 12_000, 8_000)
            + line("A-WALL", 12_000, 8_000, 0, 8_000) + line("A-WALL", 0, 8_000, 0, 0) + line("A-DOOR", 1_000, 0, 1_900, 0)
        text += "0\nENDSEC\n0\nEOF\n"
        return Data(text.utf8)
    }()

    static func write(_ data: Data, named name: String) throws -> (url: URL, directory: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("zpdf-dxf-service-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return (url, directory)
    }

    @Test("The worker draws the room: millimetres from the file, 1:20, both layers — the same sheet the core draws")
    func workerConvertsTheRoom() async throws {
        let (url, directory) = try Self.write(Self.roomDXF, named: "Room.dxf")
        defer { ServiceTestSupport.remove(directory) }
        let client = ZPDFGeometryServiceClient(backend: .subprocess(executableURL: try ServiceTestSupport.geometryWorkerURL()))
        defer { Task { await client.shutdown() } }
        let sheet = try await client.convertDXF(documentAt: url, title: "Room")
        #expect(await client.workerLaunchCount == 1, "the conversion ran in the worker process")
        #expect(sheet.unitRawValue == 4 && sheet.scaleIsFromFile)
        #expect(sheet.layers == ["A-WALL", "A-DOOR"])
        // Extents 12 000 × 8 000 mm fit A0 less margins (1169 × 821 mm) first at 1:20
        // (600 × 400 mm): 1:10 would be 1200 mm wide. Hand-derived from the standard list.
        #expect(sheet.scaleDenominator == 20)
        #expect(sheet.pdf.starts(with: Data("%PDF-".utf8)))
        #expect(sheet.skipped.isEmpty)
        // The in-process fallback is the same core: the same sheet, byte for byte.
        let local = try DXFWireCodec.decode(try GeometryServiceCore.convertDXF(data: Self.roomDXF, title: "Room"))
        #expect(local == sheet)
    }

    @Test("A binary DXF is refused in the worker, with the reader's own words")
    func binaryRefused() async throws {
        let binary = Data("AutoCAD Binary DXF\r\n\u{1A}\0".utf8) + Data(repeating: 0, count: 64)
        let (url, directory) = try Self.write(binary, named: "Binary.dxf")
        defer { ServiceTestSupport.remove(directory) }
        let client = ZPDFGeometryServiceClient(backend: .subprocess(executableURL: try ServiceTestSupport.geometryWorkerURL()))
        defer { Task { await client.shutdown() } }
        do {
            _ = try await client.convertDXF(documentAt: url, title: "Binary")
            Issue.record("a binary DXF was converted")
        } catch let ZPDFServiceError.remoteFailure(domain, _, message) {
            #expect(domain == "ZPDFDXF")
            #expect(message.contains("binary DXF"), "\(message)")
        }
    }

    @Test("The service never reads past the reader's cap: one byte over is enough to refuse")
    func boundedRead() throws {
        let (url, directory) = try Self.write(Data(repeating: 0x41, count: 100), named: "Big.dxf")
        defer { ServiceTestSupport.remove(directory) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        #expect(try GeometryServiceCore.readBounded(handle, limit: 10).count == 11)
    }

    @Test("A reply that could not have come from the writer is refused before the app acts on it")
    func malformedReplyRefused() throws {
        let good = DXFWireSheet(pdf: Data("%PDF-1.7\n".utf8), scaleDenominator: 20, scaleIsFromFile: true, unitRawValue: 4,
                                pageWidthPoints: 1700, pageHeightPoints: 1134, layers: ["A-WALL"], skipped: [:])
        #expect(try DXFWireCodec.decode(DXFWireCodec.encode(good)) == good)
        var notPDF = good
        notPDF.pdf = Data("<html>".utf8)
        #expect(throws: DXFWireError.self) { try DXFWireCodec.decode(DXFWireCodec.encode(notPDF)) }
        var badUnit = good
        badUnit.unitRawValue = 99
        #expect(throws: DXFWireError.self) { try DXFWireCodec.decode(DXFWireCodec.encode(badUnit)) }
        var noPage = good
        noPage.pageWidthPoints = .nan
        #expect(throws: DXFWireError.self) { try DXFWireCodec.decode(DXFWireCodec.encode(noPage)) }
    }
}
