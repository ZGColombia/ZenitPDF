import CoreGraphics
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFExport
import ZPDFPersistence
import ZPDFTestingSupport
@testable import ZenitCLICore

/// Iteration 1: `zenit verify` fails a project the application would refuse (R-188), and
/// `zenit totals` counts every drawing of a set (R-189).
///
/// Hand-derived quantities, every page calibrated at 100 pt = 1 m: on the first drawing a
/// polylength (0,0)→(300,0)→(300,125) is 3 m + 1.25 m = 4.25 m; on the second drawing a length
/// (0,0)→(200,0) is 2 m and a count of two points is 2. The project's plan length is
/// 4.25 m + 2 m = 6.25 m and its count is 2.
@Suite("zenit CLI — iteration 1", .serialized)
struct Iter1CLITests {

    private typealias E2E = ZenitCLIEndToEndTests

    // MARK: - R-188

    @Test("R-188: verify passes a clean project and fails one edited outside Zenit PDF or carrying a foreign trigger")
    func verifyFailsWhatTheApplicationRefuses() async throws {
        let tool = try E2E.productsDirectory().appendingPathComponent("zenit")

        let clean = try await E2E.makeSaved()
        defer { try? FileManager.default.removeItem(at: clean.directory) }
        let sound = try await ProjectReader.verify(clean.package)
        #expect(sound.isSound, "\(sound.problems)")
        let (cleanStatus, cleanOutput) = try E2E.run(tool, ["verify", clean.package.path])
        #expect(cleanStatus == 0)
        #expect(cleanOutput.contains("integrity checked"))

        // documents/working.pdf edited by another program.
        let edited = try await E2E.makeSaved()
        defer { try? FileManager.default.removeItem(at: edited.directory) }
        let working = edited.package.appendingPathComponent(ProjectPackageLayout.workingPDF)
        let handle = try FileHandle(forWritingTo: working)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n% appended by another program\n".utf8))
        try handle.close()
        let tampered = try await ProjectReader.verify(edited.package)
        #expect(!tampered.isSound)
        #expect(tampered.integrity.outcome == .modifiedOutsideZenitPDF)
        #expect(tampered.integrity.mismatchedMembers.contains(ProjectPackageLayout.workingPDF))
        // Old output: status 0, "ok: CLI Fixture.zpdfproj opens cleanly (integrity checked)".
        let (tamperedStatus, tamperedOutput) = try E2E.run(tool, ["verify", edited.package.path])
        #expect(tamperedStatus == 1)
        #expect(!tamperedOutput.contains("ok:"))

        // A foreign trigger, with integrity.json re-sealed so the schema is the only thing wrong.
        let hostile = try await E2E.makeSaved()
        defer { try? FileManager.default.removeItem(at: hostile.directory) }
        try HostileProjectPackage.apply(.extraTrigger, toPackageAt: hostile.package)
        let foreign = try await ProjectReader.verify(hostile.package)
        #expect(foreign.integrity.isVerified, "precondition: only the schema is wrong")
        #expect(foreign.schemaDeviations.contains { $0.name == HostileProjectPackage.attackerTriggerName })
        #expect(!foreign.isSound)
        #expect(try E2E.run(tool, ["verify", hostile.package.path]).status == 1)
    }

    // MARK: - R-189

    /// A saved project of two drawings, each with its own takeoff.
    static func makeTwoDrawingProject() async throws -> (directory: URL, package: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("zenit-cli-set-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let firstPDF = try ZPDFFixtures.make(.titleBlockSheet, in: directory.appendingPathComponent("first")).url
        let secondPDF = try ZPDFFixtures.make(.singleLine, in: directory.appendingPathComponent("second")).url

        let packageURL = directory.appendingPathComponent("Set.zpdfproj", isDirectory: true)
        let package = try await ProjectPackage.create(at: packageURL, displayName: "Set", originalPDF: firstPDF)
        let secondRow = try await package.addDocument(originalPDF: secondPDF, displayName: "Second sheet")
        let primaryRow = try #require(try await TakeoffArchive.drawingRows(of: package).first { $0.isPrimary }?.id)

        let firstID = DocumentID(UUID()), secondID = DocumentID(UUID())
        let firstPages = try E2E.pages(of: firstPDF, documentID: firstID)
        let secondPages = try E2E.pages(of: secondPDF, documentID: secondID)
        let session = try TakeoffSession(documentID: firstID, pages: firstPages + secondPages, units: .metric)
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        func record(_ document: DocumentID, _ page: PageID, _ tool: MeasurementTool, _ subject: String,
                    _ geometry: MeasurementGeometry) -> ZPDFContracts.MarkupRecord {
            ZPDFContracts.MarkupRecord(id: MarkupID(UUID()), documentID: document, pageID: page, kind: .measurement, tool: tool,
                                       subject: subject, label: subject, author: "Estimator", style: .default,
                                       geometry: geometry, createdAt: now, modifiedAt: now)
        }
        let a = firstPages[0].id, b = secondPages[0].id
        for page in [a, b] {
            _ = try await session.calibrate(page: page, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
                                            knownLength: 1, knownLengthUnit: .metre)
        }
        _ = try await session.apply(.addMarkup(record(firstID, a, .polylength, "Wall", MeasurementGeometry(pageID: a, points: [
            PDFPoint(x: 0, y: 0), PDFPoint(x: 300, y: 0), PDFPoint(x: 300, y: 125)]))))
        _ = try await session.apply(.addMarkup(record(secondID, b, .length, "Kerb", MeasurementGeometry(pageID: b, points: [
            PDFPoint(x: 0, y: 0), PDFPoint(x: 200, y: 0)]))))
        _ = try await session.apply(.addMarkup(record(secondID, b, .count, "Post", MeasurementGeometry(pageID: b, countPoints: [
            CountPoint(id: CountPointID(UUID()), position: PDFPoint(x: 10, y: 10), sequenceNumber: 1),
            CountPoint(id: CountPointID(UUID()), position: PDFPoint(x: 20, y: 10), sequenceNumber: 2)]))))

        try await TakeoffArchive.writeSet(await session.takeoffState(), into: package,
                                          documentRows: [firstID: primaryRow, secondID: secondRow])
        _ = try await package.save()
        try await package.close()
        return (directory, packageURL)
    }

    @Test("R-189: totals and info cover every drawing of a set, matching the hand-derived sums")
    func totalsCoverEveryDrawing() async throws {
        let project = try await Self.makeTwoDrawingProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }

        let loaded = try await ProjectReader(url: project.package).load()
        #expect(loaded.drawingCount == 2)
        #expect(loaded.markupCount == 3)
        let totals = ProjectReader.totals(try await ProjectReader.projection(
            loaded, preparedBy: "Estimator", timestamps: E2E.Clock(), timeZone: .gmt))
        let sums = Dictionary(totals.filter { $0.function == "Sum" }.map { ($0.title, $0.value) },
                              uniquingKeysWith: { first, _ in first })
        // Old output: planLength 4.25 and no count — the primary drawing only, reported as the
        // project's totals.
        #expect(sums["planLength"] == "6.25", "\(totals)")
        #expect(sums["count"] == "2", "\(totals)")

        let tool = try E2E.productsDirectory().appendingPathComponent("zenit")
        let (status, output) = try E2E.run(tool, ["info", project.package.path])
        #expect(status == 0)
        #expect(output.contains("drawings: 2"))
        #expect(output.contains("markups: 3"))
    }
}
