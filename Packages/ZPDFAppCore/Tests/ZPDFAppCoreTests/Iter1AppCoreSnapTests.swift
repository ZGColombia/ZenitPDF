import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFGeometry
import ZPDFSnapEngine
import ZPDFTestingSupport
import ZPDFVectorExtraction

/// K-01 (snap): Vector Snap on page 2 and later.
///
/// The fixture is `page-mixed-sizes`: four sheets, each with one border rectangle inset 36 pt
/// from its media box (`PageGeometryFixtures.mixedPageSizes`, `sheetInset = 36`). Hand-derived
/// corners, 1 pt = 25.4/72 mm:
/// - sheet 2 (index 1), ISO A4 210 × 297 mm = 595.2755905511811 × 841.8897637795276 pt: the
///   top-right corner is (595.2755905511811 − 36, 841.8897637795276 − 36)
///   = (559.2755905511811, 805.8897637795276);
/// - sheet 3 (index 2), ISO A1 594 × 841 mm = 1683.7795275590552 × 2383.937007874016 pt: the
///   bottom-right corner is (1683.7795275590552 − 36, 36) = (1647.7795275590552, 36).
///
/// Old output: the session held a snap index for the first sheet only, `resolveSnap` on any other
/// sheet threw `unknownPage`, the presenters' `try?` read that as "no candidate", and a click
/// 3 pt from the corner stayed 3 pt from the corner.
@Suite("Iteration 1 — Vector Snap on every page (K-01)")
@MainActor
struct Iter1AppCoreSnapTests {

    /// Every page the environment asked to have built, in order.
    final class BuildLog {
        var pages: [Int] = []
    }

    static let layout = PageViewLayout(zoom: 1, backingScale: 2)

    static func wait(upTo seconds: Double = 30, for condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    func makeEnvironment(in directory: URL) async throws -> (AppCoreEnvironment, TakeoffSession, OpenedFixture, BuildLog) {
        let fixture = try await OpenedFixture.open(.mixedPageSizes, in: directory)
        #expect(fixture.pages.count == 4)
        let session = try TakeoffSession(documentID: fixture.documentID, pages: fixture.pages)
        let environment = try await AppCoreEnvironment.make(session: session, documentID: fixture.documentID)
        let log = BuildLog()
        let url = fixture.url
        // The app's source extracts through the geometry service; the test extracts in process
        // with the same `CGPDFScanner` extractor, then builds through the same session call.
        environment.snapIndexSource = { page in
            log.pages.append(page.index)
            let extraction = try? await VectorExtractor().extract(documentAt: url, pageIndex: page.index)
            let availability = try? await session.buildSnapIndex(page: page, extraction: extraction)
            return AppCoreEnvironment.SnapIndexBuild(availability: availability)
        }
        return (environment, session, fixture, log)
    }

    @Test("Turning to sheets 2 and 3 builds their snap indexes, and a click 3 pt from a corner lands on it")
    func vectorSnapOnLaterSheets() async throws {
        let scratch = try TemporaryDirectory()
        defer { scratch.remove() }
        let directory = scratch.url
        let (environment, session, fixture, log) = try await makeEnvironment(in: directory)
        let sheet1 = fixture.pages[0].id, sheet2 = fixture.pages[1].id, sheet3 = fixture.pages[2].id

        // Installing the source builds the sheet on screen, the first.
        #expect(await Self.wait { await session.snapAvailability(page: sheet1) != nil })
        #expect(await session.snapAvailability(page: sheet2) == nil, "nothing is built before it is shown")

        environment.document.goToPage(id: sheet2.rawValue)
        #expect(await Self.wait { await session.snapAvailability(page: sheet2) != nil })
        #expect(await Self.wait { environment.canvas.isVectorSnapAvailable }, "the canvas says Vector Snap is ready on sheet 2")
        let a4Right = 210 * (72.0 / 25.4) - 36   // 559.2755905511811
        let a4Top = 297 * (72.0 / 25.4) - 36     // 805.8897637795276
        let onA4 = try await session.resolveSnap(pageID: sheet2, pagePoint: PDFPoint(x: a4Right - 3, y: a4Top - 3), layout: Self.layout)
        let a4Winner = try #require(onA4.winner, "a corner 3 pt away is inside the snap radius")
        #expect(a4Winner.kind == .endpoint)
        #expect(Swift.abs(onA4.resolvedPagePoint.x - 559.2755905511811) < 1e-9)
        #expect(Swift.abs(onA4.resolvedPagePoint.y - 805.8897637795276) < 1e-9)

        environment.document.goToPage(id: sheet3.rawValue)
        #expect(await Self.wait { await session.snapAvailability(page: sheet3) != nil })
        let a1Right = 594 * (72.0 / 25.4) - 36   // 1647.7795275590552
        let onA1 = try await session.resolveSnap(pageID: sheet3, pagePoint: PDFPoint(x: a1Right - 2, y: 36 + 2), layout: Self.layout)
        #expect(onA1.winner?.kind == .endpoint)
        #expect(Swift.abs(onA1.resolvedPagePoint.x - 1647.7795275590552) < 1e-9)
        #expect(Swift.abs(onA1.resolvedPagePoint.y - 36) < 1e-9)

        // Back to sheet 2: its index is kept, not built again.
        environment.document.goToPage(id: sheet2.rawValue)
        #expect(await Self.wait { environment.canvas.isVectorSnapAvailable })
        #expect(log.pages == [0, 1, 2], "each sheet built once: \(log.pages)")
    }

    /// A markup drawn on sheet 3 before its index exists is in the index when it is built, and a
    /// markup drawn on sheet 2 after its index was built is kept in step with it (ADR-0030 §5.7).
    @Test("A late-built index carries the markups drawn before it, and follows the ones drawn after")
    func lateIndexFollowsEdits() async throws {
        let scratch = try TemporaryDirectory()
        defer { scratch.remove() }
        let directory = scratch.url
        let (environment, session, fixture, _) = try await makeEnvironment(in: directory)
        let sheet2 = fixture.pages[1], sheet3 = fixture.pages[2]
        func line(on page: ZPDFContracts.PageDescriptor, _ a: PDFPoint, _ b: PDFPoint) -> ZPDFContracts.MarkupRecord {
            ZPDFContracts.MarkupRecord(
                id: MarkupID(UUID()), documentID: fixture.documentID, pageID: page.id, kind: .line,
                geometry: MeasurementGeometry(pageID: page.id, points: [a, b]),
                createdAt: Date(timeIntervalSince1970: 1_790_000_000), modifiedAt: Date(timeIntervalSince1970: 1_790_000_000)
            )
        }
        // Drawn on sheet 3 while only sheet 1 has an index.
        try await environment.commands.perform(.addMarkup(line(on: sheet3, PDFPoint(x: 400, y: 500), PDFPoint(x: 600, y: 500))))

        environment.document.goToPage(id: sheet2.id.rawValue)
        #expect(await Self.wait { await session.snapAvailability(page: sheet2.id) != nil })
        // Drawn on sheet 2 after its index was built.
        try await environment.commands.perform(.addMarkup(line(on: sheet2, PDFPoint(x: 200, y: 300), PDFPoint(x: 300, y: 350))))
        let onSheet2 = try await session.resolveSnap(pageID: sheet2.id, pagePoint: PDFPoint(x: 302, y: 351), layout: Self.layout)
        #expect(onSheet2.winner?.kind == .markupVertex)
        #expect(onSheet2.resolvedPagePoint.x == 300 && onSheet2.resolvedPagePoint.y == 350)

        environment.document.goToPage(id: sheet3.id.rawValue)
        #expect(await Self.wait { await session.snapAvailability(page: sheet3.id) != nil })
        let onSheet3 = try await session.resolveSnap(pageID: sheet3.id, pagePoint: PDFPoint(x: 598, y: 502), layout: Self.layout)
        #expect(onSheet3.winner?.kind == .markupVertex)
        #expect(onSheet3.resolvedPagePoint.x == 600 && onSheet3.resolvedPagePoint.y == 500)
    }

    @Test("A layer change drops the other sheets' indexes of that drawing, and keeps the one on screen")
    func layerChangeDropsOtherSheets() async throws {
        let scratch = try TemporaryDirectory()
        defer { scratch.remove() }
        let directory = scratch.url
        let (environment, session, fixture, log) = try await makeEnvironment(in: directory)
        let sheet1 = fixture.pages[0].id, sheet2 = fixture.pages[1].id
        #expect(await Self.wait { await session.snapAvailability(page: sheet1) != nil })
        environment.document.goToPage(id: sheet2.rawValue)
        #expect(await Self.wait { await session.snapAvailability(page: sheet2) != nil })

        await session.discardSnapIndexes(ofDrawing: fixture.documentID, keeping: sheet2)
        #expect(await session.snapAvailability(page: sheet1) == nil)
        #expect(await session.snapAvailability(page: sheet2) != nil)
        // Turning back rebuilds it under the new layer state.
        environment.document.goToPage(id: sheet1.rawValue)
        #expect(await Self.wait { await session.snapAvailability(page: sheet1) != nil })
        #expect(log.pages == [0, 1, 0])
    }
}
