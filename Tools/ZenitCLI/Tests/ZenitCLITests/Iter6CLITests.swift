import CoreGraphics
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFExport
import ZPDFPersistence
@testable import ZenitCLICore

/// Iteration 6: `zenit export` labels and scales its pages the way the application does
/// (W-093).
@Suite("zenit CLI — iteration 6", .serialized)
struct Iter6CLITests {

    private typealias E2E = ZenitCLIEndToEndTests

    /// A two-page drawing whose `/PageLabels` name the sheets "A-101" and "A-102"
    /// (`/P (A-) /St 101`, decimal), and whose first page declares `/UserUnit 2`.
    private static func writeLabelledUserUnitPDF(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("Labelled.pdf")
        let content = Data("1 w 0 0 0 RG\n72 72 m 372 72 l S\n".utf8)
        var stream = Data("<< /Length \(content.count) >>\nstream\n".utf8)
        stream.append(content)
        stream.append(Data("\nendstream".utf8))
        let objects: [Data] = [
            Data("<< /Type /Catalog /Pages 2 0 R /PageLabels << /Nums [0 << /S /D /P (A-) /St 101 >>] >> >>".utf8),
            Data("<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>".utf8),
            Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 842 595] /UserUnit 2 /Contents 5 0 R >>".utf8),
            Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 842 595] /Contents 5 0 R >>".utf8),
            stream,
        ]
        var bytes = Data("%PDF-1.7\n".utf8)
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(bytes.count)
            bytes.append(Data("\(index + 1) 0 obj\n".utf8))
            bytes.append(object)
            bytes.append(Data("\nendobj\n".utf8))
        }
        let xref = bytes.count
        bytes.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets { bytes.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        bytes.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        try bytes.write(to: url)
        return url
    }

    /// Old output: the CLI's pages were labelled "1" and "2" with a user unit of 1, so its export
    /// had Page "1" where the application's had "A-101", and its Scale header read "1:200" for the
    /// 1:100 preset — `ratioText` divides the page's user unit back out, and the CLI's page had
    /// none to divide by. The CSV bytes therefore differed from the application's.
    ///
    /// Hand-derived quantity: a 72 pt line on a `/UserUnit 2` page is 2 in = 0.0508 m on paper,
    /// and at 1:100 that is 5.08 m — the stored scale matrix gives it on both paths.
    @Test("W-093: the CLI export carries the application's page labels and /UserUnit scale text")
    func exportCarriesTheApplicationsLabelsAndUserUnit() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-cli-w093-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pdf = try Self.writeLabelledUserUnitPDF(in: directory)

        // The pages as the application builds them: the labels its `/PageLabels` reader resolves
        // (hand-derived from the catalog above) and the `/UserUnit` the loader reads.
        let documentID = DocumentID(UUID())
        let box = PageBoxes(media: PDFRect(x: 0, y: 0, width: 842, height: 595))
        let pages = [
            ZPDFContracts.PageDescriptor(id: PageID(UUID()), documentID: documentID, index: 0, label: "A-101",
                                         boxes: box, userUnit: 2),
            ZPDFContracts.PageDescriptor(id: PageID(UUID()), documentID: documentID, index: 1, label: "A-102",
                                         boxes: box, userUnit: 1),
        ]
        let session = try TakeoffSession(documentID: documentID, pages: pages, units: .metric)
        _ = try await session.setPresetScale(page: pages[0].id, ratioDenominator: 100)
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        _ = try await session.apply(.addMarkup(ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: documentID, pageID: pages[0].id, kind: .measurement, tool: .polylength,
            subject: "Wall", label: "Wall", author: "Estimator", style: .default,
            geometry: MeasurementGeometry(pageID: pages[0].id, points: [PDFPoint(x: 72, y: 72), PDFPoint(x: 144, y: 72)]),
            createdAt: now, modifiedAt: now)))

        let packageURL = directory.appendingPathComponent("Labelled.zpdfproj", isDirectory: true)
        let package = try await ProjectPackage.create(at: packageURL, displayName: "Labelled", originalPDF: pdf)
        try await TakeoffArchive.write(await session.takeoffState(), into: package)
        _ = try await package.save()
        try await package.close()

        let loaded = try await ProjectReader(url: packageURL).load()
        let loadedPages = await loaded.session.takeoffState().pages
        #expect(loadedPages.map(\.label) == ["A-101", "A-102"], "old: [\"1\", \"2\"]")
        #expect(loadedPages.map(\.userUnit) == [2, 1], "old: [1, 1]")

        let application = try await E2E.applicationProjection(session, name: "Labelled")
        let cli = try await ProjectReader.projection(loaded, preparedBy: "Estimator", timestamps: E2E.Clock(), timeZone: .gmt)

        #expect(cli.table.metadata.document.scaleDescription == "1:100", "old: 1:200")
        #expect(cli.table.metadata.document.scaleDescription == application.table.metadata.document.scaleDescription)
        let pageColumn = try #require(cli.table.columns.firstIndex { $0.title == "Page" || $0.key == "pageLabel" },
                                      "no Page column in \(cli.table.columns.map(\.key))")
        #expect(cli.table.rows.map { $0.cells[pageColumn].text } == ["A-101"], "old: [\"1\"]")
        #expect(try CSVExporter().export(cli) == CSVExporter().export(application))
        #expect(ZenitJSONExporter().export(cli) == ZenitJSONExporter().export(application))

        let sums = Dictionary(ProjectReader.totals(cli).filter { $0.function == "Sum" }.map { ($0.title, $0.value) },
                              uniquingKeysWith: { first, _ in first })
        #expect(sums["planLength"] == "5.08", "\(sums)")
    }

    /// The application's rule (BH-068), which the CLI now reads through the same
    /// `PageUserUnits` (X-051): a value the contract would refuse becomes 1, and the cap is 75 000.
    @Test("W-093: the CLI sanitises /UserUnit by the application's rule")
    func userUnitSanitisedLikeTheApplication() {
        #expect(PageUserUnits.sanitised(2) == 2)
        #expect(PageUserUnits.sanitised(-3) == 1)
        #expect(PageUserUnits.sanitised(0) == 1)
        #expect(PageUserUnits.sanitised(.nan) == 1)
        #expect(PageUserUnits.sanitised(.infinity) == 1)
        #expect(PageUserUnits.sanitised(1e9) == 75_000)
    }
}
