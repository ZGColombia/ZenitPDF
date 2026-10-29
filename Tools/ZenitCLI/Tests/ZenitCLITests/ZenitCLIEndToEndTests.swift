import CoreGraphics
import CryptoKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFExport
import ZPDFPersistence
import ZPDFTestingSupport
@testable import ZenitCLICore

/// NL-PLAT-13 end to end: a takeoff saved through the real package pipeline, then read by the CLI.
/// The CLI's totals equal the totals of the live session digit for digit, its exports are the
/// same bytes the application's export path writes from the same projection, and the package is
/// not touched by a single byte.
///
/// Hand-derived quantities, at 100 pt = 1 m: a polylength (0,0)→(300,0)→(300,125) is
/// 3 m + 1.25 m = 4.25 m; a 200 × 100 pt rectangle is 2 m × 1 m = 2 m²; a count of three points is 3.
@Suite("zenit CLI end to end — NL-PLAT-13", .serialized)
struct ZenitCLIEndToEndTests {

    struct Clock: TimestampProviding {
        func now() -> Date { Date(timeIntervalSince1970: 1_790_000_000) }
    }

    /// A saved project and the session it was saved from.
    struct Saved {
        let directory: URL
        let package: URL
        let session: TakeoffSession
        let name = "CLI Fixture"
    }

    static func pages(of url: URL, documentID: DocumentID) throws -> [ZPDFContracts.PageDescriptor] {
        let document = try #require(CGPDFDocument(url as CFURL))
        return try (1...document.numberOfPages).compactMap { number -> ZPDFContracts.PageDescriptor? in
            guard let page = document.page(at: number) else { return nil }
            let media = page.getBoxRect(.mediaBox), crop = page.getBoxRect(.cropBox)
            return ZPDFContracts.PageDescriptor(
                id: PageID(UUID()), documentID: documentID, index: number - 1, label: String(number),
                boxes: PageBoxes(media: PDFRect(x: media.minX, y: media.minY, width: media.width, height: media.height),
                                 crop: PDFRect(x: crop.minX, y: crop.minY, width: crop.width, height: crop.height)),
                rotation: try PageRotation.normalizing(degrees: 0))
        }
    }

    static func makeSaved() async throws -> Saved {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("zenit-cli-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pdf = try ZPDFFixtures.make(.titleBlockSheet, in: directory).url
        let documentID = DocumentID(UUID())
        let pages = try pages(of: pdf, documentID: documentID)
        let session = try TakeoffSession(documentID: documentID, pages: pages, units: .metric)
        let page = pages[0].id
        _ = try await session.calibrate(page: page, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
                                        knownLength: 1, knownLengthUnit: .metre)
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        func record(_ tool: MeasurementTool, _ subject: String, _ geometry: MeasurementGeometry) -> ZPDFContracts.MarkupRecord {
            ZPDFContracts.MarkupRecord(id: MarkupID(UUID()), documentID: documentID, pageID: page, kind: .measurement, tool: tool,
                         subject: subject, label: subject, author: "Estimator", style: .default, geometry: geometry,
                         createdAt: now, modifiedAt: now)
        }
        _ = try await session.apply(.addMarkup(record(.polylength, "Wall", MeasurementGeometry(pageID: page, points: [
            PDFPoint(x: 0, y: 0), PDFPoint(x: 300, y: 0), PDFPoint(x: 300, y: 125)]))))
        _ = try await session.apply(.addMarkup(record(.area, "Slab", MeasurementGeometry(pageID: page, polygons: [
            PolygonGeometry(outer: PolygonRing(points: [PDFPoint(x: 400, y: 400), PDFPoint(x: 600, y: 400),
                                                        PDFPoint(x: 600, y: 500), PDFPoint(x: 400, y: 500)], isClosed: true))]))))
        _ = try await session.apply(.addMarkup(record(.count, "Door", MeasurementGeometry(pageID: page, countPoints: [
            CountPoint(id: CountPointID(UUID()), position: PDFPoint(x: 10, y: 10), sequenceNumber: 1),
            CountPoint(id: CountPointID(UUID()), position: PDFPoint(x: 20, y: 10), sequenceNumber: 2),
            CountPoint(id: CountPointID(UUID()), position: PDFPoint(x: 30, y: 10), sequenceNumber: 3)]))))

        let packageURL = directory.appendingPathComponent("CLI Fixture.zpdfproj", isDirectory: true)
        let package = try await ProjectPackage.create(at: packageURL, displayName: "CLI Fixture", originalPDF: pdf)
        try await TakeoffArchive.write(await session.takeoffState(), into: package)
        _ = try await package.save()
        try await package.close()
        return Saved(directory: directory, package: packageURL, session: session)
    }

    /// The projection the application's File ▸ Export… builds from a session: its report title,
    /// its options (``ExportProjectionOptions/ledgerExport``), a fixed clock.
    static func applicationProjection(_ session: TakeoffSession, name: String) async throws -> ExportProjection {
        let (report, _) = try await session.exportReportWithDiagnostics(
            title: ExportProjectionOptions.ledgerReportTitle(documentName: name), timestamps: Clock())
        let snapshot = try await session.snapshot()
        return try ExportProjector().project(report, options: .ledgerExport(
            documentName: name, scaleDescription: snapshot.documentScaleDescription, preparedBy: "Estimator",
            screenDecimalPlaces: snapshot.units.metricDecimalPlaces, timeZone: .gmt))
    }

    /// Every file under the package with its SHA-256, for "nothing was written".
    static func fingerprint(_ url: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        let base = url.standardizedFileURL.path
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey])
        while let item = enumerator?.nextObject() as? URL {
            guard (try item.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
            let data = try Data(contentsOf: item)
            result[String(item.standardizedFileURL.path.dropFirst(base.count))] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        return result
    }

    @Test("Totals read by the CLI equal the live session's, digit for digit, and match the hand-derived values")
    func totalsEqual() async throws {
        let saved = try await Self.makeSaved()
        defer { try? FileManager.default.removeItem(at: saved.directory) }
        let before = try Self.fingerprint(saved.package)

        let live = ProjectReader.totals(try await Self.applicationProjection(saved.session, name: saved.name))
        let loaded = try await ProjectReader(url: saved.package).load()
        let read = ProjectReader.totals(try await ProjectReader.projection(loaded, preparedBy: "Estimator", timestamps: Clock(), timeZone: .gmt))
        #expect(read.map(\.title) == live.map(\.title))
        #expect(read.map(\.text) == live.map(\.text))
        #expect(read.map(\.value) == live.map(\.value))
        #expect(read.map(\.unit) == live.map(\.unit))
        #expect(read.map(\.function) == live.map(\.function))
        // Hand-derived raw sums in SI units.
        let sums = Dictionary(read.filter { $0.function == "Sum" }.map { ($0.title, $0.value) }, uniquingKeysWith: { first, _ in first })
        #expect(sums["planLength"] == "4.25", "\(read)")
        #expect(sums["planArea"] == "2", "\(read)")
        #expect(sums["count"] == "3", "\(read)")
        #expect(loaded.markupCount == 3)
        try await Task.sleep(for: .milliseconds(200))   // the reader's close is asynchronous
        let after = try Self.fingerprint(saved.package)
        #expect(after == before, "the CLI wrote to the package: \(Set(after.keys).symmetricDifference(before.keys)) changed \(after.filter { before[$0.key] != $0.value }.keys.sorted())")
    }

    @Test("CSV, XLSX and JSON from the CLI are the bytes the application writes from the same takeoff")
    func exportsIdentical() async throws {
        let saved = try await Self.makeSaved()
        defer { try? FileManager.default.removeItem(at: saved.directory) }
        let before = try Self.fingerprint(saved.package)
        let application = try await Self.applicationProjection(saved.session, name: saved.name)
        let loaded = try await ProjectReader(url: saved.package).load()
        let cli = try await ProjectReader.projection(loaded, preparedBy: "Estimator", timestamps: Clock(), timeZone: .gmt)

        #expect(try CSVExporter().export(cli) == CSVExporter().export(application))
        #expect(ZenitJSONExporter().export(cli) == ZenitJSONExporter().export(application))
        let a = saved.directory.appendingPathComponent("app.xlsx"), b = saved.directory.appendingPathComponent("cli.xlsx")
        try XLSXExporter().export(application, to: a)
        try XLSXExporter().export(cli, to: b)
        #expect(try Data(contentsOf: a) == Data(contentsOf: b))
        try await Task.sleep(for: .milliseconds(200))
        #expect(try Self.fingerprint(saved.package) == before)
    }

    @Test("The zenit executable prints the same totals as JSON, and refuses bad input with its exit codes")
    func executable() async throws {
        let saved = try await Self.makeSaved()
        defer { try? FileManager.default.removeItem(at: saved.directory) }
        let live = ProjectReader.totals(try await Self.applicationProjection(saved.session, name: saved.name))
        let tool = try Self.productsDirectory().appendingPathComponent("zenit")

        let (status, output) = try Self.run(tool, ["totals", saved.package.path, "--json"])
        #expect(status == 0)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        let totals = try #require(object["totals"] as? [[String: String]])
        #expect(totals.map { $0["value"] ?? "" } == live.map(\.value))
        #expect(totals.map { $0["text"] ?? "" } == live.map(\.text))
        #expect(object["project"] as? String == "CLI Fixture")

        #expect(try Self.run(tool, ["totals", saved.directory.appendingPathComponent("nope.pdf").path]).status == 1)
        #expect(try Self.run(tool, ["frobnicate"]).status == 2)
    }

    static func run(_ tool: URL, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    static func productsDirectory() throws -> URL {
        var info = Dl_info()
        var candidates: [URL] = []
        if dladdr(#dsohandle, &info) != 0, let name = info.dli_fname {
            candidates.append(URL(fileURLWithPath: String(cString: name)).deletingLastPathComponent())
        }
        candidates.append(Bundle.main.bundleURL)
        for start in candidates {
            var directory = start.standardizedFileURL
            for _ in 0..<6 {
                if FileManager.default.isExecutableFile(atPath: directory.appendingPathComponent("zenit").path) { return directory }
                directory.deleteLastPathComponent()
            }
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
