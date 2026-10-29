import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFPersistence
import ZPDFUIPresentation

/// NL-QTY-15 phase 2: a batch summary over closed project packages, read-only.
///
/// Two packages on the same sheet, calibrated 100 pt = 10 m (0.1 m/pt):
/// - "North": Slab 40 × 30 pt = 4 m × 3 m = 12 m², Wall 20 × 10 pt = 2 m × 1 m = 2 m².
/// - "South": Slab 20 × 10 pt = 2 m².
/// Combined: Slab 12 + 2 = 14 m², Wall 2 m². A folder that is not a project is named, not dropped.
@Suite("Quantities, round 2 — batch summary")
@MainActor
struct NLQuantitiesBatchSummaryTests {

    func writeProject(named name: String, rectangles: [(String, Double, Double)], in directory: URL) async throws -> URL {
        let folder = directory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pdf = try await OpenedFixture.open(.titleBlockSheet, in: folder)
        let url = directory.appendingPathComponent("\(name).zpdfproj", isDirectory: true)
        let package = try await ProjectPackage.create(at: url, displayName: name, originalPDF: pdf.url)
        let session = try TakeoffSession(documentID: pdf.documentID, pages: pdf.pages)
        let environment = try await AppCoreEnvironment.make(session: session, documentID: pdf.documentID)
        let page = pdf.firstPage
        try await environment.commands.calibrate(
            page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 10, knownLengthUnit: .metre
        )
        for (subject, width, height) in rectangles {
            try await environment.commands.perform(.addMarkup(ZPDFContracts.MarkupRecord(
                id: MarkupID(UUID()), documentID: pdf.documentID, pageID: page.id,
                kind: .measurement, tool: .area, subject: subject, author: "test",
                geometry: MeasurementGeometry(pageID: page.id, polygons: [PolygonGeometry(outer: PolygonRing(points: [
                    PDFPoint(x: 0, y: 0), PDFPoint(x: width, y: 0), PDFPoint(x: width, y: height), PDFPoint(x: 0, y: height)
                ], isClosed: true))]),
                createdAt: Date(timeIntervalSince1970: 1_700_000_000), modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )))
        }
        try await TakeoffArchive.write(await session.takeoffState(), into: package)
        try await package.close()
        return url
    }

    @Test("Two closed projects combine exactly by subject; a non-project is named with its reason")
    func batchOverClosedPackages() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-batch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let north = try await writeProject(named: "North", rectangles: [("Slab", 40, 30), ("Wall", 20, 10)], in: directory)
        let south = try await writeProject(named: "South", rectangles: [("Slab", 20, 10)], in: directory)
        let bogus = directory.appendingPathComponent("Bogus.zpdfproj", isDirectory: true)
        try FileManager.default.createDirectory(at: bogus, withIntermediateDirectories: true)

        let outcome = await ProjectBatchSummary.summarise([north, south, bogus], units: .metric, localeIdentifier: "en_US_POSIX")
        #expect(outcome.drawings.map(\.title) == ["North", "South"])
        let northTotals = Dictionary(uniqueKeysWithValues: outcome.drawings[0].totals.map { ($0.subject, $0.quantity.value) })
        #expect(northTotals == ["Slab": 12, "Wall": 2])
        let combined = Dictionary(uniqueKeysWithValues: outcome.combined.map { ($0.subject, $0.quantity.value) })
        #expect(combined == ["Slab": 14, "Wall": 2])
        #expect(outcome.combined.first { $0.subject == "Slab" }?.rowCount == 2)
        #expect(outcome.refused.map(\.name) == ["Bogus"])
        #expect(!(outcome.refused.first?.reason.isEmpty ?? true))

        // Read-only: nothing was written into the packages — no session marker left behind.
        let reopened = try await ProjectPackage.open(at: north)
        guard case let .opened(package) = reopened else {
            Issue.record("a batch-read package no longer opens clean: \(reopened)")
            return
        }
        try await package.close()
    }
}
